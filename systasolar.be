import mqtt

class SerialTest
  var ser, buffer, topic_prefix
  var collecttime, last_values, topics
  var last_serial_time, alive_state, serialtimeout
  var stoercode_map, status_map
  var last_published_stoercode, last_published_status
  var last_published_alive_state
  var last_publish_time

  def init()
    self.ser = serial(8, -1, 9600, serial.SERIAL_8N1)
    self.topic_prefix = "systasolar" + "/"
    self.buffer = []
    self.collecttime = tasmota.millis()
    self.last_serial_time = self.collecttime
    self.alive_state = nil
    self.last_values = {}
    self.last_published_stoercode = nil
    self.last_published_status = nil
    self.last_published_alive_state = -1
    self.last_publish_time = self.collecttime
    self.serialtimeout = 30000

    self.topics = [
      ["TSA", "float10", 4, 2, "°C"],
      ["TSE", "float10", 6, 2, "°C"],
      ["TWU", "float10", 8, 2, "°C"],
      ["TW2", "float10", 10, 2, "°C"],
      ["PSO", "hex", 12, 1, "%"],
      ["ULV", "hex", 13, 1, ""],
      ["Status", "hex", 14, 1, ""],
      ["Stoercode", "hex", 15, 1, ""],
      ["Frostschutz", "hex", 16, 1, ""],
      ["Ctr", "hex", 17, 1, ""],
      ["Stunde", "int", 18, 1, ""],
      ["Minute", "int", 19, 1, ""],
      ["Tag", "int", 20, 1, ""],
      ["Monat", "int", 21, 1, ""],
      ["Fehlzirk", "hex", 22, 2, ""],      
      ["kWhTag", "hex", 24, 4, "kWh"],
      ["kWhSumme", "hex", 28, 4, "kWh"],
      ["Jahr", "int", 32, 1, ""]
    ]

    for idx : 0 .. size(self.topics) - 1
      self.last_values[self.topics[idx][0]] = nil
    end

    self.stoercode_map = {
      0: "Keine Störung",
      1: "Blockade oder Pumpe defekt",
      2: "Luft in der Anlage",
      3: "Kein Volumenstr. Frostsch.",
      4: "VL/RL Kollektor vertauscht",
      5: "Rückschlagklappe undicht",
      6: "Falsche Uhrzeit",
      7: "Druckabfall in der Anlage",
      8: "Volumenstrom zu hoch",
      9: "Hydr. Anschl. fehlerhaft",
      10: "Anlage nicht frostsicher",
      11: "Stromvers. unregelmäßig",
      12: "TWU, ULV o. Wärmetauscher",
      13: "Volumenstrom zu niedrig",
      14: "Speicher unterkühlt",
      22: "Fühler TSA defekt",
      23: "Fühler TSE defekt",
      24: "Fühler TWU defekt",
      26: "Fühler TW2 defekt",
      34: "Speicher überhitzt",
      35: "Speicher 2 überhitzt",
      50: "Frostgefahr"
    }

    self.status_map = {
      0: "Aus, Speichertemp. erreicht",
      1: "Aus, Dampf im Kollektor",
      2: "Frostschutz aktiv",
      3: "Einspeisen",
      4: "Anschieben",
      5: "Einschaltverzögerung",
      6: "Manuell",
      7: "Störabschaltung",
      8: "Aus, Kollektortemp. zu niedrig"
    }

    tasmota.set_timer(0, /->self.loop())
  end

  def loop()
    if self.buffer.size() > 0
      self.process_buffer()
    end
    self.serialpoll()
    self.update_serialalive()
    tasmota.set_timer(50, /->self.loop())
  end

  def update_serialalive()
    var now = tasmota.millis()

    if now - self.last_serial_time > self.serialtimeout
      if self.alive_state != 0
        self.alive_state = 0
        self.publish_mqtt(self.topic_prefix + "serialalive", "0", true)
      end
    else
      if self.alive_state != 1
        self.alive_state = 1
        self.publish_mqtt(self.topic_prefix + "serialalive", "1", false)
      end
    end
  end

  def serialpoll()
    while self.ser.available() > 0
      var block = self.ser.read()
      if block && block[0] == 0xFC && block.size() == block[1] + 3
        self.buffer.push(block)
        self.last_serial_time = tasmota.millis()
      end
    end
  end

  def process_buffer()
    if size(self.buffer) == 0
      return
    end

    var block = self.buffer.pop(0)
    var new_values = {}

    for idx : 0 .. size(self.topics) - 1
      var entry = self.topics[idx]
      var topic = entry[0]
      var fmt = entry[1]
      var offset = entry[2]
      var length = entry[3]
      var value

      if length == 1
        value = block[offset]
      elif length == 2
        value = (block[offset] << 8) + (block[offset + 1])
      elif length == 4
        value = (block[offset] << 24) + (block[offset + 1] << 16) + (block[offset + 2] << 8) + block[offset + 3]
      else
        value = nil
      end

      if fmt == "float10"
        value = format("%.1f", value / 10.0)
      elif fmt == "int"
        value = int(format("%02X", value))
      elif fmt == "hex"
        value = int(value)
      end

      new_values[topic] = value
    end

    if mqtt.connected()
      if new_values["Minute"] != self.last_values["Minute"]
        self.last_values = new_values
        self.send_all_values()
        self.publish_texts(new_values, true)
      else
        for idx : 0 .. size(self.topics) - 1
          var topic = self.topics[idx][0]
          if self.last_values[topic] != new_values[topic]
            self.last_values[topic] = new_values[topic]
            self.send_value(topic, new_values[topic], false)
            self.publish_texts(new_values, false)
          end
        end
      end
    end
  end

  def send_all_values()
    for idx : 0 .. size(self.topics) - 1
      var topic = self.topics[idx][0]
      var value = self.last_values[topic]
      self.publish_mqtt(self.topic_prefix + topic, str(value))
    end
    self.publish_mqtt(self.topic_prefix + "serialalive", str(self.alive_state))
  end

  def send_value(topic, value)
    self.publish_mqtt(self.topic_prefix + topic, str(value))
  end

  def publish_texts(values, force)
    if values.has("Stoercode") && (force || values["Stoercode"] != self.last_published_stoercode)
      var code = values["Stoercode"]
      var text = self.stoercode_map.has(code) ? self.stoercode_map[code] : "Unbekannte Störung"
      self.publish_mqtt(self.topic_prefix + "StoercodeText", text)
      self.last_published_stoercode = code
    end

    if values.has("Status") && (force || values["Status"] != self.last_published_status)
      var code = values["Status"]
      var text = self.status_map.has(code) ? self.status_map[code] : "Unbekannter Status"
      self.publish_mqtt(self.topic_prefix + "StatusText", text)
      self.last_published_status = code
    end
  end

  def publish_mqtt(topic, value)
    if mqtt.connected()
      mqtt.publish(topic, value, false)
    end
  end


  def web_sensor()
    if !self.ser return nil end  # Exit if not initialized
    import string

    var format_str = ""
    var arg_str = []

    var i = 0
    while i < self.topics.size()
      var topic = self.topics[i]
      var key = topic[0]
      var fmt = topic[1]
      var unit = str(topic[4])

      if self.last_values.has(key) && self.last_values[key] != nil
        var value = str(self.last_values[key])
        format_str += "{s}" + key + "{m}" + value + " " + unit + "{e}"
      end

      i += 1
    end

    var msg = format_str
    tasmota.web_send_decimal(msg)
  end
end

serialtest = SerialTest()
tasmota.add_driver(serialtest)

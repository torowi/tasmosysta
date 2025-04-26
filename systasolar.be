import mqtt

class SerialTest
  var ser, buffer, topic_prefix
  var collecttime, last_values, topics
  var last_serial_time, alive_state

  def init()
    self.ser = serial(8, -1, 9600, serial.SERIAL_8N1)
    self.topic_prefix = "systasolar" + "/"
    self.buffer = []
    self.collecttime = tasmota.millis()
    self.last_serial_time = self.collecttime
    self.alive_state = 0
    self.last_values = {}

    # topics: [Pfad, Typ+Format, Offset, Größe]
    self.topics = [
      ["TSA", "float10", 4, 2],
      ["TSE", "float10", 6, 2],
      ["TWU", "float10", 8, 2],
      ["TW2", "float10", 10, 2],
      ["PSO", "hex", 12, 1],
      ["Status", "hex", 14, 1],
      ["Stoercode", "hex", 15, 1],
      ["Frostschutz", "hex", 16, 1],
      ["Ctr", "hex", 17, 1],
      ["Stunde", "int", 18, 1],
      ["Minute", "int", 19, 1],
      ["Tag", "int", 20, 1],
      ["Monat", "int", 21, 1],
      ["kWhTag", "hex", 24, 4],
      ["kWhSumme", "hex", 28, 4]
    ]

    for idx : 0 .. size(self.topics) - 1
      self.last_values[self.topics[idx][0]] = nil
    end

    tasmota.set_timer(0, /->self.loop())
  end

  def loop()
    if self.buffer.size() > 0
      self.process_buffer()
    end
    self.serialpoll()
    self.update_alive_state()
    tasmota.set_timer(50, /->self.loop())
  end

  def update_alive_state()
    # Wenn mehr als 30 Sekunden vergangen sind und der Zustand nicht bereits 0 ist, setze "alive" auf 0
    if tasmota.millis() - self.last_serial_time > 30000 && self.alive_state != 0
      mqtt.publish(self.topic_prefix + "alive", "0")
      self.alive_state = 0
    # Wenn neue Daten empfangen werden, setze den Zustand auf 1
    elif tasmota.millis() - self.last_serial_time <= 30000 && self.alive_state != 1
      mqtt.publish(self.topic_prefix + "alive", "1")
      self.alive_state = 1
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
      var length = entry[3]  # Anzahl der Bytes, die für den Wert ausgelesen werden müssen
      var value

      # Berechnung des Wertes basierend auf der Länge
      if length == 1
        value = block[offset]  # 1 Byte Wert
      elif length == 2
        value = (block[offset] << 8) + block[offset + 1]  # 2 Bytes Wert
      elif length == 4
        value = (block[offset] << 24) + (block[offset + 1] << 16) + (block[offset + 2] << 8) + block[offset + 3]  # 4 Bytes Wert
      else
        value = nil  # Falls es eine unerwartete Länge gibt, setze den Wert auf nil
      end

      # Formatierung des Wertes
      if fmt == "float10"
        value = value / 10.0  # Formatierung für float10
      elif fmt == "hex"
        value = int(format("%02X", value))  # Formatierung für Hex
      elif fmt == "int"
        value = int(value)  # Formatierung für Integer
      end

      new_values[topic] = value
    end

    # Update der gespeicherten Werte und Überprüfung auf Änderungen
    if self.last_values["Minute"] != new_values["Minute"]
      for idx : 0 .. size(self.topics) - 1
        var topic = self.topics[idx][0]
        self.last_values[topic] = new_values[topic]
      end
      self.send_all_values()
      return
    end

    for idx : 0 .. size(self.topics) - 1
      var topic = self.topics[idx][0]
      var fmt = self.topics[idx][1]
      self.check_and_publish(topic, new_values[topic], fmt)
    end
  end

  def check_and_publish(topic, value, fmt)
    if self.last_values[topic] != value
      mqtt.publish(self.topic_prefix + topic, str(value))
      self.last_values[topic] = value
    end
  end

  def send_all_values()
    for idx : 0 .. size(self.topics) - 1
      var topic = self.topics[idx][0]
      var fmt = self.topics[idx][1]
      var value = self.last_values[topic]
      mqtt.publish(self.topic_prefix + topic, str(value))
    end
  end
end

var test = SerialTest()

import mqtt

class SerialTest
  var ALIVE_TIMEOUT
  var ser, buffer, topic_prefix
  var collecttime, last_values, topics
  var last_serial_time, alive_state

  def init()
    self.ALIVE_TIMEOUT = 30000
    self.ser = serial(8, -1, 9600, serial.SERIAL_8N1)
    self.topic_prefix = "systasolar"
    self.buffer = []
    self.collecttime = tasmota.millis()
    self.last_serial_time = self.collecttime
    self.alive_state = 0
    self.last_values = {}

    self.topics = [
      ["/TSA", "float", "%.1f", 10.0, 4],
      ["/TSE", "float", "%.1f", 10.0, 6],
      ["/TWU", "float", "%.1f", 10.0, 8],
      ["/TW2", "float", "%.1f", 10.0, 10],
      ["/PSO", "int", nil, 1.0, 12],
      ["/Status", "int", nil, 1.0, 14],
      ["/Stoercode", "int", nil, 1.0, 15],
      ["/Frostschutz", "int", nil, 1.0, 16],
      ["/Ctr", "int", nil, 1.0, 17],
      ["/Stunde", "int", nil, 1.0, 18],
      ["/Minute", "int", nil, 1.0, 19],
      ["/Tag", "int", nil, 1.0, 20],
      ["/Monat", "int", nil, 1.0, 21],
      ["/kWhTag", "int", nil, 1.0, 24],
      ["/kWhSumme", "int", nil, 1.0, 28]
    ]

    for idx : 0 .. self.topics.size() - 1
      var topic = self.topics[idx][0]
      self.last_values[topic] = nil
    end

    tasmota.set_timer(0, /->self.loop())
  end

  def loop()
    self.serialpoll()
    self.process_buffer()

    if tasmota.millis() - self.last_serial_time > self.ALIVE_TIMEOUT && self.alive_state != 0
      mqtt.publish(self.topic_prefix + "/alive", "0")
      self.alive_state = 0
    end

    tasmota.set_timer(50, /->self.loop())
  end

  def serialpoll()
    while self.ser.available() > 0
      var block = self.ser.read()
      if block && block[0] == 0xFC && block.size() == block[1] + 3
        self.buffer.push(block)
        self.last_serial_time = tasmota.millis()
        if self.alive_state != 1
          mqtt.publish(self.topic_prefix + "/alive", "1")
          self.alive_state = 1
        end
      end
    end
  end

  def process_buffer()
    if self.buffer.size() == 0
      return
    end

    var block = self.buffer.pop(0)

    var current_values = {}

    for idx : 0 .. self.topics.size() - 1
      var topic = self.topics[idx][0]
      var typ = self.topics[idx][1]
      var fmt = self.topics[idx][2]
      var div = self.topics[idx][3]
      var offset = self.topics[idx][4]

      var value
      if topic == "/kWhTag" || topic == "/kWhSumme"
        value = (block[offset] << 24) + (block[offset+1] << 16) + (block[offset+2] << 8) + block[offset+3]
      else
        value = block[offset]
        if topic == "/TSA" || topic == "/TSE" || topic == "/TWU" || topic == "/TW2"
          value = (block[offset] << 8) + block[offset+1]
        end
      end

      # Für Stunde/Minute/Tag/Monat hex-dekodieren
      if topic == "/Stunde" || topic == "/Minute" || topic == "/Tag" || topic == "/Monat"
        value = int(str("%02X", value))
      end

      # Divisor anwenden, falls nötig
      if div != 1.0
        value = value / div
      end

      current_values[topic] = value
    end

    # Wenn sich die Minute geändert hat → alles publishen
    if self.last_values["/Minute"] != current_values["/Minute"]
      for idx : 0 .. self.topics.size() - 1
        var topic = self.topics[idx][0]
        self.publish_value(topic, current_values[topic])
        self.last_values[topic] = current_values[topic]
      end
      return
    end

    # Einzelne Änderungen publishen
    for idx : 0 .. self.topics.size() - 1
      var topic = self.topics[idx][0]
      if self.last_values[topic] != current_values[topic]
        self.publish_value(topic, current_values[topic])
        self.last_values[topic] = current_values[topic]
      end
    end
  end

  def publish_value(topic, value)
    for idx : 0 .. self.topics.size() - 1
      if self.topics[idx][0] == topic
        var fmt = self.topics[idx][2]
        if fmt
          mqtt.publish(self.topic_prefix + topic, str(fmt, value))
        else
          mqtt.publish(self.topic_prefix + topic, str(value))
        end
        break
      end
    end
  end
end

var test = SerialTest()

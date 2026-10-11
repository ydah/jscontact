# frozen_string_literal: true

require_relative "../lib/jscontact"

# RSS includes the Ruby process and retained heap, not just the parsed Card.
def resident_bytes
  Integer(IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).strip) * 1024
rescue SystemCallError, ArgumentError
  nil
end

base = { "@type" => "Card", "version" => "2.0" }
limit = JSContact::DEFAULT_LIMITS
empty = JSON.generate(base.merge("example.test:data" => ""))
maximum_input = JSON.generate(base.merge("example.test:data" => "x" * (limit[:max_input_size] - empty.bytesize)))
maps = limit[:max_map_size].times.to_h { |index| ["e#{index}", { "address" => "user#{index}@example.test" }] }
nested = 31.times.reduce("leaf") { |value, _| { "next" => value } }
uri = "data:application/octet-stream;base64,#{["a" * limit[:max_data_uri_size]].pack("m0")}"
cases = [
  ["input_at_limit", maximum_input, "accepted"],
  ["input_over_limit", "#{maximum_input} ", "rejected"],
  ["map_at_limit", JSON.generate(base.merge("emails" => maps)), "accepted"],
  ["map_over_limit", JSON.generate(base.merge("emails" => maps.merge("overflow" => { "address" => "extra@example.test" }))), "rejected"],
  ["depth_at_limit", JSON.generate(base.merge("example.test:data" => nested)), "accepted"],
  ["depth_over_limit", JSON.generate(base.merge("example.test:data" => { "next" => nested })), "rejected"],
  ["data_uri_at_limit", JSON.generate(base.merge("example.test:data" => uri)), "accepted"],
  ["data_uri_over_limit", JSON.generate(base.merge("example.test:data" => "#{uri}AAAA")), "rejected"]
]

results = cases.map do |name, source, expected|
  GC.start
  before_memory = resident_bytes
  before_objects = GC.stat[:total_allocated_objects]
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = "accepted"
  begin
    JSContact.parse(source)
  rescue JSContact::LimitError
    result = "rejected"
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  allocated_objects = GC.stat[:total_allocated_objects] - before_objects
  raise "#{name}: expected #{expected}, got #{result}" unless result == expected

  { name: name, source_bytes: source.bytesize, result: result, elapsed_seconds: elapsed.round(6),
    allocated_objects: allocated_objects, rss_before_bytes: before_memory, rss_bytes: resident_bytes }
end

puts JSON.pretty_generate(results)

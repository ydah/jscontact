# Resource boundary measurements

Run `bundle exec ruby script/benchmark.rb` to check accepted and rejected inputs
at the default limits. Every case asserts its expected result and reports elapsed
time, allocated Ruby objects, and process RSS when `ps` is available.

On Ruby 4.0.6 / macOS, measured on 2026-10-11:

| Accepted input | Elapsed time | Process RSS after parsing |
| --- | ---: | ---: |
| 16 MiB JSON document | 1.15 s | 96 MiB |
| 10,000 email map entries | 0.28 s | 113 MiB |
| 32 nested JSON containers | 0.00020 s | 116 MiB |
| Data URI encoding 1 MiB | 0.10 s | 116 MiB |

The matching over-limit cases were rejected. The JSON byte and nesting limits
reject during or before parsing; map and data URI limits run during validation.
Schema-defined collections use the map limit, while arbitrary extension data is
bounded by JSON size and nesting. Localization patches also have a separate
1,000-entry limit verified by the test suite.

These are single-process development measurements, not throughput guarantees or
peak-memory measurements. RSS includes all benchmark inputs, loaded dependencies,
and retained Ruby heap from earlier cases. The script prints `null` for RSS where
process inspection is unavailable. Adjust the documented limit options downward
for applications with smaller memory or latency budgets.

Unicode validation iterates code points without materializing an array: the same
16 MiB case previously grew process RSS to about 352 MiB. The streaming check keeps
that temporary allocation out of the parser's memory budget.

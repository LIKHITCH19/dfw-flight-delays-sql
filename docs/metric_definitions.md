# Metric definitions

| metric | definition | notes |
|---|---|---|
| On-time departure % | departed less than 15 min after schedule ÷ flights that weren't cancelled | DOT departure definition |
| On-time arrival % | arrived less than 15 min late ÷ all scheduled flights | cancelled and diverted count as not on time (DOT definition) |
| Cancel % | cancelled ÷ scheduled | |
| Delay minutes | sum of the five BTS cause fields | only exists on flights that arrived 15+ late, same as DOT reporting |
| Late-aircraft share | late aircraft minutes ÷ delay minutes | |
| "American" | carriers AA, MQ (Envoy), OH (PSA) | the `american_group` flag; SkyWest/Republic flights for American Eagle aren't included |
| Linked flight | same tail, previous flight landed at this flight's origin, not diverted, plane on the ground 0-6 h (actual times) | |
| Inherits delay | linked AND carrier coded late-aircraft minutes on it | |
| Chain | a non-inheriting flight (the root) followed by 1+ inheriting flights on the same tail | |
| Aircraft swap | chain root landed <15 min late and the next flight's scheduled turn was under 15 min (usually negative) | the plane wasn't scheduled to make that departure |
| Scheduled turn | next scheduled departure − previous scheduled arrival, same airport | |
| Pass-through % | of inbound flights 15+ late, the share whose next departure also left 15+ late | |
| Practical minimum turn | 10th percentile of actual turn time when the inbound was 30+ min late | per fleet: mainline 50, regional 34 |
| Buffer | scheduled turn − practical minimum turn | |
| Chronically delayed flight | carrier + flight number + origin + dest scheduled 10+ times in a month, and more than 50% of them arrived 30+ min late, were cancelled or diverted | DOT rule, 14 CFR 399.81 |
| Chronic streak | consecutive months the same flight was chronically delayed | DOT problem starts above 4 months |
| Cost of delay | delay minutes × $98.41 | A4A 2025 direct aircraft operating cost per block minute, stored in `mart.assumptions` |

# Metric definitions

| metric | definition | notes |
|---|---|---|
| On-time departure % | departed less than 15 min after schedule ÷ flights that weren't cancelled | DOT departure definition |
| On-time arrival % | arrived less than 15 min late ÷ all scheduled flights | cancelled and diverted count as not on time (DOT definition) |
| Cancel % | cancelled ÷ scheduled | |
| Delay minutes | sum of the five BTS cause fields | only exists on flights that arrived 15+ late, same as DOT reporting |
| Late-aircraft share | late aircraft minutes ÷ delay minutes | |
| "American" | carriers AA, MQ (Envoy), OH (PSA) | the `american_group` flag; SkyWest/Republic flights for American Eagle aren't included |

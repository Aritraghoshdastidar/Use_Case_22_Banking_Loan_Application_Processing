%dw 2.0
output application/java
var base = p('notify.backoffBaseSeconds') as Number
var grace = p('notify.pendingGraceSeconds') as Number
// seconds a notification must have waited before attempt n+1: base x (2^n - 1)
fun wait(attempts) = base * ([0, 1, 3, 7, 15, 31, 63, 127][attempts] default 127)
---
(payload default []) filter ((n) ->
	(n.status == "RETRYING" and n.ageSeconds >= wait(n.attempts))
	or (n.status == "PENDING" and n.ageSeconds >= grace))

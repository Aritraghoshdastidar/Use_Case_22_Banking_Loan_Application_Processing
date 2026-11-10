%dw 2.0
output application/java
var rules = vars.rules.rules
var all = (vars.reused default []) ++ (vars.fresh default [])
var accepted1 = (all filter ((r) -> r.status == "ACCEPTED")) orderBy ((r) -> r.fileName)
var kept = (accepted1 groupBy ((r) -> r.sha256)) pluck ((group) -> group[0].key)
var results = all map ((r) ->
	if (r.status == "ACCEPTED" and !(kept contains r.key))
		({(r - "status" - "reason")} ++ {status: "DUPLICATE", reason: "DUPLICATE_CONTENT"})
	else r)
var accepted = results filter ((r) -> r.status == "ACCEPTED")
var missingTypes = rules
	map ((r) -> {docType: r.docType, required: r.requiredCount, found: sizeOf(accepted filter ((a) -> a.docType == r.docType))})
	filter ((t) -> t.found < t.required)
---
{
	results: results,
	accepted: accepted,
	quarantined: results filter ((r) -> r.status == "QUARANTINED"),
	duplicates: results filter ((r) -> r.status == "DUPLICATE"),
	missingTypes: missingTypes,
	complete: isEmpty(missingTypes)
}

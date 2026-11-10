%dw 2.0
output application/java
var manifest = vars.app.manifest
var declared = manifest.documentCount default 0
var found = sizeOf(vars.reconciliation.present)
var declaredSums = (manifest.documents default []) filter ((m) -> m.sha256 != null)
var mismatches = declaredSums
	map ((m) -> {
		fileName: m.fileName,
		declared: lower(m.sha256),
		found: (vars.validation.accepted filter ((a) -> a.fileName == m.fileName))[0].sha256
	})
	filter ((c) -> c.found != null and c.declared != c.found)
---
{
	declaredCount: declared,
	foundCount: found,
	countMatches: declared == found,
	checksumMismatches: mismatches,
	agrees: declared == found and isEmpty(mismatches)
}

%dw 2.0
output application/java
var prefix = vars.prefix
var rules = vars.rules.rules
var checklistTypes = rules map ((r) -> r.docType)
var manifestDocs = vars.app.manifest.documents default []
var objects = payload default []
var files = (objects filter ((o) -> !(o.key endsWith "/"))) map ((o) -> {
	key: o.key,
	fileName: o.key[sizeOf(prefix) to -1],
	size: o.size,
	lastModified: (o.lastModified default "") as String
})
var direct = files filter ((f) -> !(f.fileName contains "/"))
var nested = files filter ((f) -> f.fileName contains "/")
fun expectedType(name) = (manifestDocs filter ((m) -> m.fileName == name and (checklistTypes contains m."type")))[0]."type"
var typed = direct map ((f) -> f ++ {docType: expectedType(f.fileName)})
var present = typed filter ((f) -> f.docType != null)
var presentNames = present map ((f) -> f.fileName)
---
{
	folderFound: !isEmpty(objects),
	present: present,
	unexpected: (typed filter ((f) -> f.docType == null) map ((f) -> f - "docType")) ++ nested,
	missingFiles: manifestDocs
		filter ((m) -> (checklistTypes contains m."type") and !(presentNames contains m.fileName))
		map ((m) -> {fileName: m.fileName, docType: m."type"}),
	missingTypes: rules
		map ((r) -> {docType: r.docType, required: r.requiredCount, found: sizeOf(present filter ((f) -> f.docType == r.docType))})
		filter ((t) -> t.found < t.required)
}

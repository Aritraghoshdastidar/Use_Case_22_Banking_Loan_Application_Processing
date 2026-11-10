%dw 2.0
output application/java
---
{
	key: vars.file.key,
	fileName: vars.file.fileName,
	docType: vars.file.docType,
	size: vars.actualSize,
	status: if (vars.reason == null) "ACCEPTED" else "QUARANTINED",
	reason: vars.reason,
	sha256: vars.sha256
}

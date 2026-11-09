%dw 2.0
output application/java
var head = lower(vars.headHex default "")
var tail = lower(vars.tailHex default "")
var detected = if (head startsWith "255044462d") "application/pdf"
	else if (head startsWith "ffd8ff") "image/jpeg"
	else if (head startsWith "89504e470d0a1a0a") "image/png"
	else null
var ext = lower((vars.file.fileName splitBy ".")[-1])
var extMime = if (ext == "pdf") "application/pdf"
	else if (ext == "jpg" or ext == "jpeg") "image/jpeg"
	else if (ext == "png") "image/png"
	else null
var typeOk = detected != null and detected == extMime and (vars.rule.allowedMimeTypes contains detected)
var complete = if (detected == "application/pdf") (tail contains "2525454f46")
	else if (detected == "image/png") (tail endsWith "49454e44ae426082")
	else if (detected == "image/jpeg") (tail endsWith "ffd9")
	else false
---
if (!typeOk) "UNSUPPORTED_TYPE" else if (!complete) "EMPTY_OR_UNREADABLE" else null

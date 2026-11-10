%dw 2.0
output application/json
---
{
	code: vars.errorCode,
	message: if (vars.errorCode == "NOT_FOUND" or vars.errorCode == "CONFLICT" or vars.errorCode == "BAD_REQUEST")
		(error.description default "Request could not be processed")
	else
		"Request could not be processed",
	correlationId: correlationId
}

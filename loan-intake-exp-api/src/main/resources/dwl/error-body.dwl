%dw 2.0
output application/json
---
{
	code: vars.errorCode,
	message: if (["NOT_FOUND", "CONFLICT", "BAD_REQUEST", "UNPROCESSABLE"] contains vars.errorCode)
		(error.description default "Request could not be processed")
	else
		"Request could not be processed",
	correlationId: correlationId
} ++ (if (vars.errorDetails != null) { details: { errors: vars.errorDetails } } else {})

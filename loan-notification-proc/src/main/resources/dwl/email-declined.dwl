%dw 2.0
import * from modules::notice
output application/java
var app = vars.app
---
{
	subject: "An update on your loan application $(app.applicationId)",
	body: ([
		"Dear $(app.applicantName),",
		"",
		"Thank you for applying for a $(productLabel(app.productCode)). After careful consideration we are not able to approve application $(app.applicationId).",
		"",
		"The main reasons are:"
	] ++ (declineReasons(app.decision.reasonCodes) map ((r) -> "- $(r)")) ++ [
		"",
		"This decision was made on the information available to us at the time.",
		"",
		"You have the right to ask for the decision to be reviewed. To request a review, write to $(p('mail.reviewContact')) within $(p('mail.reviewDays')) days, quoting your reference $(app.applicationId). You may add any information you would like us to consider.",
		"",
		"Your reference: $(app.applicationId)"
	]) joinBy "\n"
}

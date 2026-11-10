%dw 2.0
import * from modules::notice
output application/java
var app = vars.app
---
{
	subject: "Your loan application $(app.applicationId) is under review",
	body: ([
		"Dear $(app.applicantName),",
		"",
		"Thank you for applying for a $(productLabel(app.productCode)). Your application $(app.applicationId) needs a closer look from one of our underwriters before we can give you an answer.",
		"",
		"What to expect: we aim to give you a decision within $(p('mail.referralDays')) working days. We will email you as soon as it is made.",
		"",
		"You do not need to do anything now. If we need more information from you we will contact you directly.",
		"",
		"Your reference: $(app.applicationId)"
	]) joinBy "\n"
}

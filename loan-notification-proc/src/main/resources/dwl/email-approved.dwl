%dw 2.0
import * from modules::notice
output application/java
var app = vars.app
var d = app.decision
var reduced = d.reductionReason != null
---
{
	subject: "Your loan application $(app.applicationId) is approved",
	body: ([
		"Dear $(app.applicantName),",
		"",
		"Good news: your $(productLabel(app.productCode)) application $(app.applicationId) has been approved.",
		"",
		"Approved amount: $(money(d.approvedAmount))",
		"Term: $(d.approvedTenure) months",
		"Interest rate: $(money(d.approvedRatePct))% a year",
		"Monthly instalment: $(money(d.instalment))",
		"This offer is valid until $(plainDate(d.offerExpiresAt)).",
		""
	] ++ (if (reduced) [
		"Please note that we have approved less than you asked for. You requested $(money(d.requestedAmount)). The monthly instalment on that amount would have been more than we can lend against your income after your existing commitments, so we reduced the amount to the largest sum that fits.",
		""
	] else []) ++ [
		"What happens next:",
		"1. Check the terms above.",
		"2. Accept the offer before it expires by replying to this email or contacting your branch with your reference.",
		"3. We will then prepare your loan agreement for signature.",
		"",
		"Your reference: $(app.applicationId)"
	]) joinBy "\n"
}

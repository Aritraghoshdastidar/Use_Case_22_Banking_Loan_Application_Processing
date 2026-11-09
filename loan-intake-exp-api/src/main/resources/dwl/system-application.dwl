%dw 2.0
output application/json
var r = vars.request
---
{
	requestId: r.requestId,
	payloadHash: vars.payloadHash,
	correlationId: vars.applicationCorrelationId,
	productCode: r.productCode,
	requestedAmount: r.amount,
	requestedTenure: r.tenureMonths,
	applicantName: r.applicant.fullName,
	dateOfBirth: r.applicant.dateOfBirth,
	identityRef: r.applicant.identityRef,
	email: r.applicant.email,
	monthlyIncome: r.applicant.monthlyIncome,
	monthlyObligations: r.applicant.monthlyObligations default 0,
	employmentMonths: r.applicant.employmentMonths default 0,
	manifest: {
		folder: r.documents.folder,
		documentCount: r.documents.documentCount,
		documents: r.documents.documents default []
	}
}

%dw 2.0
output application/java
var p = vars.product
var r = vars.request
var dob = r.applicant.dateOfBirth as Date {format: "yyyy-MM-dd"}
var age = floor(daysBetween(dob, now() as Date) / 365.25)
fun outside(v, low, high) = v < low or v > high
fun whole(v) = floor(v) as String
---
flatten([
	if (outside(r.amount, p.minAmount, p.maxAmount))
		[{ field: "amount", message: "Amount must be between " ++ whole(p.minAmount) ++ " and " ++ whole(p.maxAmount) ++ " for product " ++ p.code }]
	else [],
	if (outside(r.tenureMonths, p.minTenureMonths, p.maxTenureMonths))
		[{ field: "tenureMonths", message: "Tenure must be between " ++ (p.minTenureMonths as String) ++ " and " ++ (p.maxTenureMonths as String) ++ " months for product " ++ p.code }]
	else [],
	if (outside(age, p.minAgeAtApplication, p.maxAgeAtApplication))
		[{ field: "applicant.dateOfBirth", message: "Applicant age must be between " ++ (p.minAgeAtApplication as String) ++ " and " ++ (p.maxAgeAtApplication as String) ++ " at application for product " ++ p.code }]
	else []
])

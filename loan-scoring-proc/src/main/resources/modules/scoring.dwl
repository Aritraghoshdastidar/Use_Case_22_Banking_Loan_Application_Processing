%dw 2.0

// Rounding to 2 or 4 decimals, half up
fun round2(x) = round(x * 100) / 100
fun round4(x) = round(x * 10000) / 10000

// Monthly instalment factor r(1+r)^n / ((1+r)^n - 1), with r = annual rate / 1200
fun emiFactor(annualRatePct, months) = do {
	var r = annualRatePct / 1200
	---
	if (r == 0) 1 / months
	else do {
		var growth = java!java::lang::Math::pow((1 + r) as Number {class: "double"}, months as Number {class: "double"})
		---
		r * growth / (growth - 1)
	}
}

// Indicative instalment for an amount, rounded to 2 decimals
fun emi(principal, annualRatePct, months) = round2(principal * emiFactor(annualRatePct, months))

fun clamp(x, low, high) = if (x < low) low else if (x > high) high else x

// Linear points between two end values: 0 at zeroAt, 100 at fullAt, in either direction
fun points(value, zeroAt, fullAt) = round2(clamp(100 * (value - zeroAt) / (fullAt - zeroAt), 0, 100))

fun contribution(weight, pts) = round2(weight * pts / 100)

// Completed years at the end of the loan
fun ageAtMaturity(dateOfBirth, today, months) = do {
	var born = dateOfBirth as Date
	var maturity = today + ("P$(months)M" as Period)
	var years = maturity.year - born.year
	---
	if (maturity.month < born.month or (maturity.month == born.month and maturity.day < born.day)) years - 1 else years
}

// Largest multiple of the amount step whose instalment stays within the ceiling, 0 if none
fun maxAffordableAmount(maxEmi, annualRatePct, months, step) = do {
	var factor = emiFactor(annualRatePct, months)
	var guess = floor(maxEmi / factor / step) * step
	---
	if (guess <= 0) 0
	else if (emi(guess, annualRatePct, months) > maxEmi) guess - step
	else guess
}

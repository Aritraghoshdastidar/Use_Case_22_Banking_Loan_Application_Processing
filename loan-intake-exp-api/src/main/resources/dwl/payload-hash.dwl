%dw 2.0
import hashWith from dw::Crypto
import toHex from dw::core::Binaries
output application/java
---
toHex(hashWith(write(vars.request, "application/json", {indent: false}) as Binary, "SHA-256"))

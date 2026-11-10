# BouncyCastle is used through its lightweight API only (no JCA provider
# lookups), so R8 can shrink it; keep the crypto primitives NoBars calls.
-keep class org.bouncycastle.crypto.** { *; }
-dontwarn org.bouncycastle.**
-dontwarn javax.naming.**

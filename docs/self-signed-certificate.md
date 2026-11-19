# Self-signed code-signing certificate

Builds you make yourself need no Developer ID, notarization or DMG: apps built on the same Mac aren't quarantined.
They do need a **stable signing identity**, so the Accessibility grant survives rebuilds.

`Scripts/make-app.sh` picks the identity in this order:

1. `SIGN_IDENTITY=…` if set.
2. A **Developer ID Application** identity in the keychain (adds the hardened runtime and a secure timestamp, as notarization needs).
3. A self-signed certificate named **`Local Code Signing`** in the login keychain.

## Create `Local Code Signing` (once)

Either use Keychain Access › Certificate Assistant › Create a Certificate (Self-Signed Root, type Code Signing), or run:

```sh
cat > cs.cnf <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = Local Code Signing
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# /usr/bin/openssl (LibreSSL) writes a .p12 that `security import` accepts
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cs.cnf
P=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Local Code Signing" -out cs.p12 -passout pass:$P
security import cs.p12 -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign -T /usr/bin/security
rm -f key.pem cs.p12 cs.cnf   # the private key now lives only in the keychain
```

## Notes

- `security find-identity -p codesigning` lists it as `CSSMERR_TP_NOT_TRUSTED`. That's expected for a self-signed certificate.
- Signing with a different identity (ad-hoc `-`, a new certificate, a team certificate) means granting Accessibility again in System Settings.
- Remove it with `security delete-identity -c "Local Code Signing"`.

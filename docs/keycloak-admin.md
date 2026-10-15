# Keycloak administration

The production admin console is at https://auth.miak-it.com/admin/.
Cloudflare Access protects `/admin` and its subpaths, including the Admin REST
API, with the existing `access_allowed_email` allow policy and one-time PIN.
Realm endpoints under `/realms`, including Flowloom login, token, and discovery
endpoints, remain public.

The permanent master-realm administrator is `ammad`, with the master `admin`
realm role. Its generated password is stored in OpenBao at
`apps/keycloak-admin`, in `KC_ADMIN_PASSWORD`; the username is in
`KC_ADMIN_USERNAME`. After authenticating to OpenBao with an authorized account,
retrieve it through the OpenBao UI or:

```bash
bao kv get -field=KC_ADMIN_PASSWORD apps/keycloak-admin
```

The Flowloom provisioning script reads these credentials from OpenBao after
its normal admin login. They are not injected into the Keycloak deployment.
The Kubernetes `keycloak` secret contains only the database credentials.

The temporary `kc-bootstrap-admin` account was removed after independently
verifying login and administrative access with the permanent account. Bootstrap
fields were removed from the current OpenBao `apps/keycloak` version and the
ExternalSecret mapping. Historical KV versions may still contain the retired
credentials; that account no longer exists.

`scripts/keycloak-bootstrap-openbao.sh` prepares secrets for initial setup; it
does not create or recover a permanent admin. The current deployment intentionally
omits the bootstrap admin environment variables. A fresh database therefore
requires an explicit temporary-admin bootstrap, followed by permanent-admin
creation and removal of the temporary account. See the
[Keycloak bootstrap and recovery guide](https://www.keycloak.org/server/bootstrap-admin-recovery).

Cloudflare path matching follows the
[Access application paths documentation](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/).

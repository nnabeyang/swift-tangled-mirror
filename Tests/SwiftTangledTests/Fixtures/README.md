# Bobbin response fixtures

These fixtures mirror the public response shapes documented and tested by
Tangled core at revision `da1953b92c920d3beb2cbd4914387ec3189728ae`.

- Coverage and XRPC error envelopes: `bobbin/crates/xrpc/`
- Rate limit envelope and `Retry-After`: `bobbin/worker/`
- Profile, repository, search, issue, pull request, comment, reaction, label,
  and state/status shapes:
  public `api.tangled.org` Bobbin XRPC
  responses, normalized to stable example identifiers.
- Pipeline shapes: public `spindle.tangled.sh` Spindle CI XRPC responses,
  normalized to stable example identifiers and covering every trigger kind.

Fixtures contain no credentials or private data.

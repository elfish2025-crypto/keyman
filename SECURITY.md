# Security

Keyman is a credential manager for trusted users and local agents. It is not a sandbox for isolating malicious agents.

- Credentials use macOS Keychain. Configuration, guides, and call results may still contain personal information and should be treated as private data.
- MCP runs over local stdio without a separate user authentication layer. Connect it only to trusted clients.
- MCP's `authorized: true` is the caller's declaration of existing authorization, not a human approval flow, spending limit, or service purchase mechanism.
- Clients with configuration write access can change destination endpoints. Restricting requests to configured hosts does not replace trust in those clients and endpoints.
- CLI `run` passes the full credential to a child process, which can read or forward it. MCP does not expose this tool.
- The credential used for a call is redacted from provider responses. This does not guarantee removal of all sensitive data from arbitrary logs, remote URLs, or model content.
- Clearing or deleting a local credential does not revoke the provider-side key. Revoke and replace exposed credentials through the provider.

Report vulnerabilities privately through the repository's **Security → Report a vulnerability** page. Do not post keys, real account configurations, or unredacted reproduction materials in public issues. If private reporting is unavailable, open an issue without sensitive details to request a private contact channel.

The maintained application line is the latest 0.7.x version. The project does not currently promise fixed response times or long-term support releases.

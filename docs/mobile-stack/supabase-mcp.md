# Supabase MCP on Codex

This setup is prepared but requires your Supabase project ref + access token.

## Enable command

```bash
bash ~/.codex/scripts/enable-supabase-mcp.sh <your_project_ref>
```

## Required environment variable

```bash
export SUPABASE_ACCESS_TOKEN=<your_supabase_access_token>
```

## Verify

Check `~/.codex/config.toml` for:

```toml
[mcp_servers.supabase]
command = "bash"
args = ["~/.codex/scripts/run-supabase-mcp.sh", "<your_project_ref>"]
```

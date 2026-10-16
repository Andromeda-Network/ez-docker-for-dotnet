# Security Policy

## Overview

EZ Docker For .NET takes security seriously. This document outlines our security features, threat model, vulnerability reporting process, and best practices for users.

## Security Features

### 1. Input Validation & Injection Prevention

**SQL Injection Protection:**
- All database identifiers (names, usernames) validated against strict patterns
- Only alphanumeric characters and underscores allowed
- SQL Server identifier quoting with brackets (`[name]`), PostgreSQL with `%I`
- Passwords containing `'` or `]` are refused
- Names and passwords reach `sqlcmd`/`psql` as variables from the environment, never on a command line

**Command Injection Protection:**
- Input validation for all user-provided values
- Strict patterns for app names, environments, Git URLs
- No shell command execution with unvalidated input
- Proper quoting and escaping throughout

**Validation Rules:**
- **App names**: `^[a-zA-Z0-9_-]+$` (max 64 chars)
- **Environments**: Whitelist only (`dev`, `test`, `staging`, `production`)
- **Database names**: `^[a-zA-Z0-9_]+$` (max 64 chars)
- **Usernames**: `^[a-zA-Z0-9_]+$` (max 32 chars)
- **Git URLs**: Valid URL format with protocol
- **Project paths**: relative `.csproj` paths inside the repository (no `..`, no absolute paths)
- **Image tags**: Docker's tag grammar (`--tag`, `ez dotnet rollback`)

### 2. Network Security

**Database Access:**
- Every app environment gets its own database and login (`db_owner` of that database only); apps never see the `sa`/`postgres` password, which `ez` masks out of their environment along with the registry token
- Network isolation between containers is provided by Docker networks
- Database ports are not published to the host by default
- Admin UIs (Nginx Proxy Manager, Seq, Portainer) listen on `127.0.0.1` only: reach them through an SSH tunnel

**Service Exposure:**
- Development/test: Exposed on `APP_PORT` only
- Staging/production: Behind Nginx Proxy Manager
- No unnecessary port exposure
- Firewall-friendly configuration

### 3. Docker Security

**Image Version Pinning:**
- All critical services use pinned versions
- No `latest` tags in production
- Version management through `.env` configuration
- Controlled updates with testing

**Pinned Versions** (`docker/docker.env`, defaults in `.env.example`):
- Nginx Proxy Manager: 2.11.1
- SQL Server: 2022 (`MSSQL_VERSION`; pin a CU tag such as `2022-CU15-ubuntu-22.04` in production)
- PostgreSQL: 17.2
- Redis: 7.4.1
- Seq: 2024.3
- Portainer: 2.19.4

**Container Security:**
- Health checks for automatic recovery
- Restart policies for high availability
- Resource limits (configurable)
- Security options (no-new-privileges for Portainer)

### 4. Configuration Security

**Environment Variables:**
- Sensitive data in `.env` files (not in code)
- `.env` excluded from version control
- `.env.example` as template (no secrets)
- Environment-specific configurations

**App images (`template/dotnet.Dockerfile`):**
- Microsoft's `aspnet` runtime image: no SDK, compilers or source in what runs
- Runs as the image's non-root user (uid 1654); writable data only in `storage-<env>` volumes owned by it
- Secrets are never baked in: the build context's `.dockerignore` excludes env files and keys, and settings arrive as environment variables at run time
- `ASPNETCORE_ENVIRONMENT=Production` in production, so the developer exception page is off
- Health check on `/healthz`; a deploy that doesn't become healthy is rolled back

**Security headers:** set them in the app (`app.UseHsts()`, a headers middleware) or as a custom
location in Nginx Proxy Manager, which terminates TLS for every app.

### 5. Error Handling

**Secure Error Messages:**
- No sensitive information in error output
- No stack traces to users
- Detailed logging for debugging
- User-friendly error messages

### 6. Access Control

**Privilege Management:**
- No root requirement (Docker group membership)
- Minimal privilege principle
- Secure file permissions
- User-specific configurations

**Authentication:**
- Strong password generation (20+ characters)
- Special character support
- No default passwords
- Password complexity encouraged

## Threat Model

### In Scope

**Protected Against:**
- SQL injection attacks
- Command injection attacks
- Path traversal attacks
- Unauthorized database access
- Container escape attempts
- Version-specific vulnerabilities (through pinning)
- Clickjacking attacks
- XSS attacks (through headers)
- Information disclosure

### Out of Scope

**Not Protected Against:**
- Physical access to the host
- Compromised Docker daemon
- Kernel vulnerabilities
- Network-level attacks (DDoS, etc.)
- Social engineering
- Compromised dependencies (supply chain)

**User Responsibilities:**
- Keep host system updated
- Secure Docker daemon
- Manage firewall rules
- Secure SSH access
- Backup data regularly
- Monitor logs

## Security Best Practices

### For Deployment

1. **Use Strong Passwords:**
   - Use long, randomly generated passwords (20+ characters)
   - Do not reuse credentials across environments
   - Never rely on default passwords

2. **Keep Systems Updated:**
   ```bash
   # Update host system
   sudo apt update && sudo apt upgrade
   
   # Update Docker images (test first!)
   docker-compose pull
   ```

3. **Enable Firewall:**
   ```bash
   # Allow only necessary ports
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw allow 22/tcp
   sudo ufw enable
   ```

4. **Regular Backups:**
   ```bash
   # Backup databases
   SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" docker exec -e SQLCMDPASSWORD mssql /opt/mssql-tools18/bin/sqlcmd -C -U sa \
     -Q "BACKUP DATABASE [myapp_production] TO DISK = N'/var/opt/mssql/backup/myapp_production.bak' WITH COMPRESSION"
   
   # Backup volumes
   tar czf mssql-data.tar.gz shared/mssql   # with the mssql container stopped
   ```

5. **Monitor Logs:**
   ```bash
   # Check container logs
   docker logs <container_name>
   
   # Monitor health status
   docker ps --format "table {{.Names}}\t{{.Status}}"
   ```

### For Development

1. **Never Commit Secrets:**
   - Use `.env` files (gitignored)
   - Use `.env.example` for templates
   - Review commits before pushing

2. **Validate Inputs:**
   - Always validate user input
   - Use provided validation functions
   - Test with malicious inputs

3. **Follow Secure Coding:**
   - Handle errors explicitly
   - Avoid eval and dynamic execution
   - Quote variables properly
   - Use functions from the input validation module

## Vulnerability Reporting

### Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

**DO:**
- Email: sm.mirbehbahani@gmail.com
- Include detailed description
- Provide steps to reproduce
- Suggest a fix if possible
- Allow time for fix before disclosure

**DON'T:**
- Open public GitHub issues for security bugs
- Disclose publicly before fix is available
- Exploit the vulnerability

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Development**: Depends on severity
  - Critical: Within 1 week
  - High: Within 2 weeks
  - Medium: Within 1 month
  - Low: Next release
- **Public Disclosure**: After fix is released

### Severity Levels

**Critical:**
- Remote code execution
- SQL injection with data access
- Authentication bypass
- Container escape

**High:**
- Privilege escalation
- Sensitive data exposure
- Denial of service

**Medium:**
- Information disclosure
- Missing security headers
- Weak cryptography

**Low:**
- Security misconfigurations
- Best practice violations

## Security Updates

### Staying Informed

- Watch the [GitHub repository](https://github.com/Andromeda-Network/ez-docker-for-dotnet)
- Check [releases](https://github.com/Andromeda-Network/ez-docker-for-dotnet/releases) for security updates

### Applying Updates

```bash
# Pull latest changes
git pull origin main

# Review changes
git log --oneline -10

# Regenerate CLI if needed
sudo bashly generate

# Test in non-production first
./ez --version
```

## Security Checklist

### Before Production Deployment

- [ ] Change all default passwords
- [ ] Review and update `.env` files
- [ ] Enable firewall with minimal ports
- [ ] Set up SSL/TLS certificates
- [ ] Configure Nginx Proxy Manager
- [ ] Test database connectivity
- [ ] Verify health checks working
- [ ] Set up monitoring and alerting
- [ ] Configure automated backups
- [ ] Review security headers
- [ ] Test with security scanner
- [ ] Document custom configurations
- [ ] Set up log rotation
- [ ] Review file permissions
- [ ] Disable debug mode
- [ ] Test disaster recovery

### Regular Maintenance

- [ ] Update host system monthly
- [ ] Review Docker image updates
- [ ] Check security advisories
- [ ] Rotate passwords quarterly
- [ ] Review access logs
- [ ] Test backup restoration
- [ ] Verify health check status
- [ ] Update SSL certificates
- [ ] Review firewall rules
- [ ] Audit user access

## Compliance

### Data Protection

- No personal data collected by the tool
- User responsible for application data
- Database encryption at rest (user-configured)
- TLS encryption in transit (via Nginx PM)

### Logging

- No sensitive data in logs
- Passwords never logged
- Error logs contain no secrets
- User responsible for log retention

## Additional Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
- [ASP.NET Core security](https://learn.microsoft.com/aspnet/core/security/)
- [.NET container images](https://learn.microsoft.com/dotnet/core/docker/container-images)

## Contact

For security concerns:
- **Email**: sm.mirbehbahani@gmail.com
- **GitHub**: [@MansourM](https://github.com/MansourM)

For general questions:
- **GitHub Issues**: [Create an issue](https://github.com/Andromeda-Network/ez-docker-for-dotnet/issues)
- **GitHub Discussions**: [Start a discussion](https://github.com/Andromeda-Network/ez-docker-for-dotnet/discussions)

---

**Last Updated**: November 2024  
**Version**: 1.0.0

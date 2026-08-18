# AWS Free-Tier Pilot

This is the account-bound deployment path for the protocol-4 cloud race server. `cloudformation.yaml` creates the encrypted EC2/Elastic-IP/Systems-Manager/security-group/budget foundation, and `deploy.sh` refuses to run unless the named AWS profile matches the explicitly supplied 12-digit account ID and the exact commit is clean and published on `origin/main`.

## Pilot shape

- Region: `ap-south-1` (Mumbai) for the initial India-focused mobile test.
- Instance: a currently free-tier-eligible two-vCPU EC2 type; `t3.small` is the preferred x86 pilot when the account shows it as eligible.
- OS: Ubuntu Server 24.04 LTS.
- Storage: at least 30 GB encrypted gp3.
- Network: public TCP 80/443 and UDP 443; SSH only from the administrator's current IP. Do not expose PostgreSQL, Nakama API/console, or Docker.
- Budget protection: enable AWS Budgets/free-tier alerts before launch. Free-plan credit/window exhaustion must be treated as a deployment stop, not an assumed permanent entitlement.

The two-GB shape is for private acceptance traffic. Monitor memory, swap activity, CPU credits, disk, WebSocket latency, active rooms, and disconnects. Resize to at least four GB before a public rollout if any headroom gate is missed.

## Deployment

1. Authenticate the temporary `dhanush` AWS CLI profile and record the account ID returned by `aws sts get-caller-identity`.
2. Commit and publish the exact approved release candidate on `origin/main`.
3. From the repository root, deploy with the expected account guard and a USD 10 monthly alert:

   ```sh
   RACEGLYPH_AWS_ACCOUNT_ID=123456789012 \
     backend/production/aws/deploy.sh
   ```

4. Point `multiplayer.neutale.com` to the `PublicIp` stack output. CloudFormation intentionally does not guess which DNS provider owns `neutale.com`.
5. After public DNS and TLS resolve, run `backend/production/scripts/run_public_e2e.sh`.
6. Run the two-physical-phone matrix on different mobile/Wi-Fi networks before distributing the build.

## Upgrade path

The application endpoint and protocol do not change when the pilot grows. Resize EC2 first, then move PostgreSQL to managed storage and add multiple Nakama nodes behind a load balancer when measured concurrent-room demand requires it. A versioned rollout and reconnect/drain plan are required before multi-node deployment.

Firebase may be added for crash reporting, analytics, or push notifications. It must not replace the Nakama authoritative race loop or enter the steering/throttle latency path.

#!/bin/bash
# ============================================================
# EduStack — GitHub Repository Setup Script
# Run this ONCE after cloning to set up the branch structure
# Author: Samson Olanipekun
# Usage: bash setup_repo.sh
# ============================================================

set -euo pipefail

GITHUB_USER="Reich-imperial"
REPO_NAME="edustack"
REMOTE="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

echo "=============================================="
echo " EduStack — Repository Setup"
echo "=============================================="

# Verify git is installed
command -v git >/dev/null || { echo "Error: git not installed"; exit 1; }

# Initialise git if not already done
if [ ! -d .git ]; then
  echo ">>> Initialising git repository..."
  git init
fi

# Configure git identity (update with your details)
git config user.name  "Samson Olanipekun"
git config user.email "your-email@gmail.com"   # ← replace this

echo ">>> Creating .gitignore..."
cat > .gitignore << 'EOF'
# Build artifacts
target/
*.war
*.jar
*.class

# IDE files
.idea/
*.iml
.vscode/
*.swp

# Vagrant
.vagrant/
*.log

# Environment / secrets
.env
*.pem
*.key
application-prod.properties

# OS
.DS_Store
Thumbs.db
EOF

echo ">>> Staging all files..."
git add .

echo ">>> Creating initial commit on main..."
git commit -m "feat: initial EduStack project — multi-tier university portal

- 5-tier architecture: Nginx, Tomcat, MySQL, Memcached, RabbitMQ
- Manual and automated Vagrant provisioning scripts
- Docker Compose for containerised deployment
- Kubernetes manifests with HPA
- GitHub Actions DevSecOps pipeline (GitLeaks, Snyk, Trivy)
- Complete database schema with seed data
- Professional README with architecture diagrams

Author: Samson Olanipekun (github.com/Reich-imperial)"

echo ">>> Creating deployment stage branches..."
git checkout -b local-manual
git checkout main

git checkout -b local-auto
git checkout main

git checkout -b aws-lift-shift
git checkout main

git checkout -b containerised
git checkout main

git checkout -b kubernetes
git checkout main

echo ""
echo ">>> Adding remote origin..."
git remote add origin "$REMOTE" 2>/dev/null || \
  git remote set-url origin "$REMOTE"

echo ""
echo "=============================================="
echo " Setup complete! Next steps:"
echo "=============================================="
echo ""
echo " 1. Create the repo on GitHub:"
echo "    https://github.com/new"
echo "    Name: edustack"
echo "    Visibility: Public"
echo "    Do NOT initialise with README (we have one)"
echo ""
echo " 2. Push everything:"
echo "    git push -u origin main"
echo "    git push origin --all"
echo ""
echo " 3. On GitHub, set main as the default branch"
echo "    and add branch protection rules on main."
echo ""
echo " 4. Add GitHub Secrets (Settings → Secrets):"
echo "    SNYK_TOKEN, AWS_ACCOUNT_ID, EC2_HOST,"
echo "    EC2_SSH_KEY, DB_HOST, DB_PASS, RMQ_HOST, MC_HOST"
echo ""
echo "=============================================="

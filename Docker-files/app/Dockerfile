# EduStack — Tomcat Application Server Image
# Multi-stage: Stage 1 builds the WAR, Stage 2 runs it

# ── Stage 1: Build ───────────────────────────────────────────
FROM openjdk:17-slim AS BUILD_IMAGE
LABEL stage="build"

RUN apt-get update && apt-get install -y maven git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN git clone -b main https://github.com/Reich-imperial/edustack.git /app
WORKDIR /app
RUN mvn install -DskipTests

# ── Stage 2: Run ─────────────────────────────────────────────
FROM tomcat:10.1-jre17-temurin-jammy
LABEL project="EduStack"
LABEL author="Samson Olanipekun"
LABEL github="github.com/Reich-imperial/edustack"

# Remove default Tomcat apps
RUN rm -rf /usr/local/tomcat/webapps/*

# Copy built artifact from Stage 1
COPY --from=BUILD_IMAGE /app/target/EduStack.war /usr/local/tomcat/webapps/ROOT.war

# Non-root security: Tomcat already runs as non-root in this image
EXPOSE 8080

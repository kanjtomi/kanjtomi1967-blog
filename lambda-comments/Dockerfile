# Container image for running the comments service on Kubernetes (learning/staging
# replica only). The real production deployment is still the AWS Lambda function built
# from this same source and deployed by Terraform (see terraform/) — this Dockerfile
# is not part of that pipeline.
#
# Build:
#   podman build -t comments-service:local .
#   (or: docker build -t comments-service:local .)

FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/target/comments-lambda.jar app.jar

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["java", "-cp", "app.jar", "com.kanjtomi.blog.comments.HttpAdapter"]

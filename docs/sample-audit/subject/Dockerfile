# =============================================================================
# AUDIT FIXTURE — DO NOT USE
# Companion to subject/azure-pipelines.yml. See docs/sample-audit/AUDIT.md.
# =============================================================================

FROM mcr.microsoft.com/dotnet/sdk:6.0

ARG NPM_TOKEN
ARG DB_CONNECTION

WORKDIR /app

COPY . .

RUN echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc \
    && npm install \
    && rm ~/.npmrc

RUN dotnet publish src/Orders.Api/Orders.Api.csproj -c Release -o /app/out

ENV ConnectionStrings__Default=${DB_CONNECTION}
ENV ASPNETCORE_ENVIRONMENT=Production

EXPOSE 80

ENTRYPOINT ["dotnet", "/app/out/Orders.Api.dll"]

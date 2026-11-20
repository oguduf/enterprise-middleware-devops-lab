# middleware-demo

A small Java 11 Servlet application packaged as `target/middleware-demo.war`. It is the Phase A application used by this lab; deployment automation and server-specific configuration are later phases.

## Build

Install a JDK 11 (or newer JDK capable of compiling with `--release 11`) and Maven 3.9.x, then run from this directory:

```powershell
mvn clean verify
```

Maven resolves the Servlet API for compilation and tests, compiles with Java 11 language/API compatibility, runs JUnit tests, then assembles the WAR. The Servlet API has `provided` scope because the application server supplies it at runtime; bundling another copy can cause classloading conflicts.

## Endpoints

Deploy the WAR with context root `/middleware-demo` to make these paths available:

| Method | Path | Example response |
| --- | --- | --- |
| GET | `/middleware-demo/api/hello` | `{"message":"Welcome to the middleware demo"}` |
| GET | `/middleware-demo/health` | `{"status":"UP"}` |
| GET | `/middleware-demo/api/version` | `{"version":"1.0.0"}` |

The health endpoint reports that the web application is serving requests. It does not check downstream dependencies because this application has none.

## Compatibility baseline

This source uses `javax.servlet` and Servlet 4.0, with bytecode and Java APIs targeted to Java 11. Treat WebLogic 14.1.1 and JBoss EAP 7.4 as the initial learning baseline, subject to the exact server PSU, JDK certification matrix, and configured web container. Confirm those details against the vendor's documentation before using a specific patch level.

Do not assume this WAR works unchanged on every server release. WebLogic 12c includes multiple releases with different Java and Servlet support; older 12c installations may not provide Servlet 4.0. WebLogic 14c is a product family, and the exact release matters. JBoss EAP 8.1 moves to Jakarta EE APIs (`jakarta.servlet`), while EAP 7.4 uses the older Java EE `javax.servlet` namespace. Since Java package names are part of the binary API, changing the dependency alone does not convert a `javax.*` application to `jakarta.*`; the code and descriptor must be migrated and rebuilt for the target platform. Maintain target-specific variants or a verified transformation strategy where cross-version support is required.

Before a real deployment, verify the vendor support matrix for JDK, Servlet version, deployment descriptor, and application-server patch level. Oracle documents Servlet 4.0 and Java EE 8 for WebLogic 14.1.1. Red Hat's supported standards table lists Jakarta EE 8 for EAP 7.4 and Jakarta EE 10 for EAP 8.1. This lab does not certify a particular installation.

References: [Oracle WebLogic 14.1.1 What's New](https://docs.oracle.com/en/middleware/standalone/weblogic-server/14.1.1.0/notes/whatsnew.html), [Red Hat JBoss EAP Supported Standards](https://access.redhat.com/articles/113373).

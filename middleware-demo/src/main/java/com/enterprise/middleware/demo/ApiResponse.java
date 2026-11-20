package com.enterprise.middleware.demo;

/** Creates the small JSON response bodies exposed by the demo endpoints. */
public final class ApiResponse {
    public static final String VERSION = "1.0.0";

    private ApiResponse() {
    }

    public static String hello() {
        return "{\"message\":\"Welcome to the middleware demo\"}";
    }

    public static String health() {
        return "{\"status\":\"UP\"}";
    }

    public static String version() {
        return "{\"version\":\"" + VERSION + "\"}";
    }
}

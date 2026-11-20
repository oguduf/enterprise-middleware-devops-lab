package com.enterprise.middleware.demo;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class ApiResponseTest {
    @Test
    void helloReturnsWelcomeJson() {
        assertEquals("{\"message\":\"Welcome to the middleware demo\"}", ApiResponse.hello());
    }

    @Test
    void healthReturnsUpStatus() {
        assertEquals("{\"status\":\"UP\"}", ApiResponse.health());
    }

    @Test
    void versionReturnsProjectVersion() {
        assertEquals("{\"version\":\"1.0.0\"}", ApiResponse.version());
    }
}

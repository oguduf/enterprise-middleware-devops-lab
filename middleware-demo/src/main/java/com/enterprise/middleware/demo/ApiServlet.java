package com.enterprise.middleware.demo;

import java.io.IOException;
import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

/** Routes the three read-only demo endpoints. The container owns this servlet's lifecycle. */
@WebServlet(urlPatterns = {"/api/hello", "/health", "/api/version"})
public class ApiServlet extends HttpServlet {
    private static final long serialVersionUID = 1L;

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws ServletException, IOException {
        response.setCharacterEncoding("UTF-8");
        response.setContentType("application/json");

        String path = request.getServletPath();
        if ("/api/hello".equals(path)) {
            response.getWriter().write(ApiResponse.hello());
        } else if ("/health".equals(path)) {
            response.getWriter().write(ApiResponse.health());
        } else if ("/api/version".equals(path)) {
            response.getWriter().write(ApiResponse.version());
        } else {
            response.sendError(HttpServletResponse.SC_NOT_FOUND);
        }
    }
}

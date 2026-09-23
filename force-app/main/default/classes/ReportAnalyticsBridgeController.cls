public with sharing class ReportAnalyticsBridgeController {
    public String responseBody { get; private set; }

    public PageReference execute() {
        String method = ApexPages.currentPage().getParameters().get('verb');
        String path = ApexPages.currentPage().getParameters().get('path');
        String encodedBody = ApexPages.currentPage().getParameters().get('payload');
        try {
            if (String.isBlank(path) || !path.startsWith('/analytics/')) {
                responseBody = wrapper(400, '{"message":"Only analytics requests are allowed."}');
                return null;
            }
            String sessionId = UserInfo.getSessionId();
            if (String.isBlank(sessionId)) {
                responseBody = wrapper(401, '{"message":"Salesforce did not provide your session, so the report could not be saved as you."}');
                return null;
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/data/v66.0' + path);
            req.setMethod(String.isBlank(method) ? 'GET' : method);
            req.setHeader('Authorization', 'Bearer ' + sessionId);
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            if (String.isNotBlank(encodedBody)) {
                req.setBody(encodedBody);
            }

            HttpResponse res = new Http().send(req);
            responseBody = wrapper(res.getStatusCode(), res.getBody());
        } catch (Exception e) {
            responseBody = wrapper(500, JSON.serialize(new Map<String, String>{ 'message' => e.getMessage() }));
        }
        return null;
    }

    private static String wrapper(Integer status, String body) {
        return JSON.serialize(new Map<String, Object>{
            'status' => status,
            'body' => body
        });
    }
}

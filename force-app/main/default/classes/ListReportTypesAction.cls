public with sharing class ListReportTypesAction {
    @InvocableMethod(
        label='List Report Types'
        description='Finds Salesforce report types that match a plain-language subject.'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(findTypes(req));
        }
        return results;
    }

    private static Result findTypes(Request req) {
        Result result = new Result();
        result.isSuccess = false;
        result.matchesJson = '[]';
        try {
            if (req == null || String.isBlank(req.searchTerm)) {
                result.errorMessage = 'Say which records the report should cover, such as opportunities or accounts.';
                return result;
            }

            Object payload = ReportAnalyticsClient.send('GET', '/analytics/report-types', null);
            if (!(payload instanceof List<Object>)) {
                result.errorMessage = 'Salesforce did not return a list of report types.';
                return result;
            }

            List<String> tokens = tokensFor(req.searchTerm);
            List<ScoredMatch> scored = new List<ScoredMatch>();
            for (Object categoryObj : (List<Object>) payload) {
                Map<String, Object> category = (Map<String, Object>) categoryObj;
                String categoryLabel = stringValue(category.get('label'));
                List<Object> reportTypes = (List<Object>) category.get('reportTypes');
                if (reportTypes == null) {
                    continue;
                }
                for (Object typeObj : reportTypes) {
                    Map<String, Object> reportType = (Map<String, Object>) typeObj;
                    if (reportType.get('isHidden') == true) {
                        continue;
                    }
                    String label = stringValue(reportType.get('label'));
                    String typeName = stringValue(reportType.get('type'));
                    String description = stringValue(reportType.get('description'));
                    String haystack = (categoryLabel + ' ' + label + ' ' + typeName + ' ' + description).toLowerCase();
                    if (!matchesAll(haystack, tokens)) {
                        continue;
                    }
                    Boolean isDataCloud = reportType.get('isDataCloudReportType') == true;
                    Integer score = isDataCloud ? 0 : 10;
                    if (label != null && label.equalsIgnoreCase(req.searchTerm.trim())) {
                        score += 8;
                    }
                    if (typeName != null && typeName.equalsIgnoreCase(req.searchTerm.trim())) {
                        score += 8;
                    }
                    scored.add(new ScoredMatch(score, new Map<String, Object>{
                        'label' => label,
                        'type' => typeName,
                        'description' => description,
                        'category' => categoryLabel,
                        'isDataCloud' => isDataCloud
                    }));
                }
            }

            scored.sort();
            List<Map<String, Object>> matches = new List<Map<String, Object>>();
            Integer cap = Math.min(15, scored.size());
            for (Integer i = 0; i < cap; i++) {
                matches.add(scored[i].payload);
            }

            result.matchesJson = JSON.serialize(matches);
            if (matches.isEmpty()) {
                result.errorMessage = 'No report type matched "' + req.searchTerm + '". Try the object name, such as opportunities or cases.';
                return result;
            }
            result.isSuccess = true;
            result.errorMessage = '';
        } catch (Exception e) {
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    private static List<String> tokensFor(String searchTerm) {
        List<String> tokens = new List<String>();
        for (String part : searchTerm.toLowerCase().split('\\s+')) {
            if (part.length() >= 3) {
                tokens.add(part);
            }
        }
        return tokens;
    }

    private static Boolean matchesAll(String haystack, List<String> tokens) {
        if (tokens.isEmpty()) {
            return false;
        }
        for (String token : tokens) {
            if (!haystack.contains(token) && !haystack.contains(stem(token))) {
                return false;
            }
        }
        return true;
    }

    private static String stem(String token) {
        if (token.endsWith('ies') && token.length() > 4) {
            return token.substring(0, token.length() - 3) + 'y';
        }
        if (token.endsWith('s') && token.length() > 4) {
            return token.substring(0, token.length() - 1);
        }
        return token;
    }

    private static String stringValue(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    private class ScoredMatch implements Comparable {
        public Integer score;
        public Map<String, Object> payload;

        public ScoredMatch(Integer score, Map<String, Object> payload) {
            this.score = score;
            this.payload = payload;
        }

        public Integer compareTo(Object other) {
            ScoredMatch that = (ScoredMatch) other;
            return that.score - this.score;
        }
    }

    public class Request {
        @InvocableVariable(label='Search Term' description='Words naming the records, such as opportunities or accounts' required=true)
        public String searchTerm;
    }

    public class Result {
        @InvocableVariable(label='Matches JSON' description='JSON array of matching report types')
        public String matchesJson;

        @InvocableVariable(label='Is Success' description='Whether at least one report type matched')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message' description='Plain-language error. Empty on success.')
        public String errorMessage;
    }
}

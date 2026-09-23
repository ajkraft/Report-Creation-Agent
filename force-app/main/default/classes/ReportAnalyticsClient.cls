public with sharing class ReportAnalyticsClient {
    public class ReportAnalyticsException extends Exception {}

    public static Object send(String method, String path, String body) {
        // Agent actions do not receive UserInfo.getSessionId(). Rendering the
        // bridge page does, and that page makes the Analytics API call as the user.
        PageReference bridge = new PageReference('/apex/ReportAnalyticsBridge');
        bridge.getParameters().put('verb', method);
        bridge.getParameters().put('path', path);
        if (body != null) {
            bridge.getParameters().put('payload', body);
        }

        String pageBody = bridge.getContent().toString();
        Object wrapped = JSON.deserializeUntyped(pageBody);
        if (!(wrapped instanceof Map<String, Object>)) {
            throw new ReportAnalyticsException('The report request returned an unexpected response.');
        }
        Map<String, Object> envelope = (Map<String, Object>) wrapped;
        Integer status = Integer.valueOf(String.valueOf(envelope.get('status')));
        String responseBody = envelope.get('body') == null ? '' : String.valueOf(envelope.get('body'));
        if (status >= 200 && status < 300) {
            if (String.isBlank(responseBody)) {
                return new Map<String, Object>();
            }
            return JSON.deserializeUntyped(responseBody);
        }
        throw new ReportAnalyticsException(plainError(responseBody, status));
    }

    public static String plainError(String responseBody, Integer status) {
        try {
            Object parsed = JSON.deserializeUntyped(responseBody);
            if (parsed instanceof List<Object>) {
                List<Object> errors = (List<Object>) parsed;
                if (!errors.isEmpty() && errors[0] instanceof Map<String, Object>) {
                    Object message = ((Map<String, Object>) errors[0]).get('message');
                    if (message != null) {
                        return String.valueOf(message);
                    }
                }
            } else if (parsed instanceof Map<String, Object>) {
                Object message = ((Map<String, Object>) parsed).get('message');
                if (message != null) {
                    return String.valueOf(message);
                }
            }
        } catch (Exception ignored) {
            // Fall through to the generic message.
        }
        return 'Salesforce could not complete the report request (' + status + ').';
    }

    public static String encodeReportType(String reportType) {
        return EncodingUtil.urlEncode(reportType, 'UTF-8').replace('+', '%20').replace('%24', '$');
    }

    public static String lightningReportUrl(String reportId) {
        String domain = URL.getOrgDomainUrl().toExternalForm();
        domain = domain.replace('.my.salesforce.com', '.lightning.force.com');
        return domain + '/lightning/r/Report/' + reportId + '/view';
    }

    public static Map<String, Object> fetchReportType(String reportType) {
        Object payload = send('GET', '/analytics/report-types/' + encodeReportType(reportType), null);
        if (!(payload instanceof Map<String, Object>)) {
            throw new ReportAnalyticsException('Salesforce did not describe that report type.');
        }
        return (Map<String, Object>) payload;
    }

    public static List<Map<String, Object>> allColumns(Map<String, Object> payload) {
        List<Map<String, Object>> columns = new List<Map<String, Object>>();
        Map<String, Object> typeMeta = (Map<String, Object>) payload.get('reportTypeMetadata');
        if (typeMeta == null) {
            return columns;
        }
        List<Object> categories = (List<Object>) typeMeta.get('categories');
        if (categories == null) {
            return columns;
        }
        Integer categoryIndex = 0;
        for (Object categoryObj : categories) {
            Map<String, Object> category = (Map<String, Object>) categoryObj;
            Map<String, Object> columnMap = (Map<String, Object>) category.get('columns');
            if (columnMap == null) {
                categoryIndex++;
                continue;
            }
            for (String apiName : columnMap.keySet()) {
                Map<String, Object> column = (Map<String, Object>) columnMap.get(apiName);
                String dataType = stringValue(column.get('dataType'));
                columns.add(new Map<String, Object>{
                    'apiName' => apiName,
                    'label' => stringValue(column.get('label')),
                    'dataType' => dataType,
                    'filterable' => column.get('filterable') == true,
                    'category' => stringValue(category.get('label')),
                    'primary' => categoryIndex == 0,
                    'canGroup' => dataType != 'textarea' && dataType != 'html' && dataType != 'encryptedstring'
                });
            }
            categoryIndex++;
        }
        return columns;
    }

    public static List<Map<String, Object>> columnsForAgent(List<Map<String, Object>> columns, String focusTerm) {
        List<String> tokens = tokensFor(focusTerm);
        List<Map<String, Object>> selected = new List<Map<String, Object>>();
        Set<String> seen = new Set<String>();
        for (Map<String, Object> column : columns) {
            if (column.get('primary') == true && selected.size() < 50) {
                selected.add(slim(column));
                seen.add((String) column.get('apiName'));
            }
        }
        for (Map<String, Object> column : columns) {
            String apiName = (String) column.get('apiName');
            if (seen.contains(apiName) || !matchesFocus(column, tokens)) {
                continue;
            }
            selected.add(slim(column));
            seen.add(apiName);
            if (selected.size() >= 80) {
                break;
            }
        }
        return selected;
    }

    public static Set<String> columnNames(List<Map<String, Object>> columns) {
        Set<String> names = new Set<String>();
        for (Map<String, Object> column : columns) {
            names.add((String) column.get('apiName'));
        }
        return names;
    }

    public static String defaultDateColumn(Map<String, Object> payload) {
        Map<String, Object> reportMetadata = (Map<String, Object>) payload.get('reportMetadata');
        if (reportMetadata == null) {
            return '';
        }
        Map<String, Object> dateFilter = (Map<String, Object>) reportMetadata.get('standardDateFilter');
        if (dateFilter == null) {
            return '';
        }
        return stringValue(dateFilter.get('column'));
    }

    public static List<Map<String, Object>> standardFilters(Map<String, Object> payload) {
        List<Map<String, Object>> filters = new List<Map<String, Object>>();
        Map<String, Object> typeMeta = (Map<String, Object>) payload.get('reportTypeMetadata');
        if (typeMeta == null) {
            return filters;
        }
        Map<String, Object> infos = (Map<String, Object>) typeMeta.get('standardFilterInfos');
        if (infos == null) {
            return filters;
        }
        for (String name : infos.keySet()) {
            Map<String, Object> info = (Map<String, Object>) infos.get(name);
            List<Map<String, String>> values = new List<Map<String, String>>();
            List<Object> filterValues = (List<Object>) info.get('filterValues');
            if (filterValues != null) {
                for (Object valueObj : filterValues) {
                    Map<String, Object> value = (Map<String, Object>) valueObj;
                    values.add(new Map<String, String>{
                        'label' => stringValue(value.get('label')),
                        'name' => stringValue(value.get('name'))
                    });
                    if (values.size() >= 8) {
                        break;
                    }
                }
            }
            filters.add(new Map<String, Object>{
                'name' => name,
                'label' => stringValue(info.get('label')),
                'values' => values
            });
        }
        return filters;
    }

    private static Map<String, Object> slim(Map<String, Object> column) {
        return new Map<String, Object>{
            'apiName' => column.get('apiName'),
            'label' => column.get('label'),
            'dataType' => column.get('dataType'),
            'filterable' => column.get('filterable'),
            'canGroup' => column.get('canGroup')
        };
    }

    private static Boolean matchesFocus(Map<String, Object> column, List<String> tokens) {
        if (tokens.isEmpty()) {
            return false;
        }
        String haystack = (stringValue(column.get('label')) + ' ' + stringValue(column.get('apiName'))).toLowerCase();
        for (String token : tokens) {
            if (haystack.contains(token) || haystack.contains(stem(token))) {
                return true;
            }
        }
        return false;
    }

    private static List<String> tokensFor(String raw) {
        List<String> tokens = new List<String>();
        if (String.isBlank(raw)) {
            return tokens;
        }
        for (String part : raw.toLowerCase().split('[^a-z0-9]+')) {
            if (part.length() >= 3) {
                tokens.add(part);
            }
        }
        return tokens;
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
}

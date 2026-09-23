public with sharing class CreateSavedReportAction {
    @InvocableMethod(
        label='Create Saved Report'
        description='Saves a Salesforce report for the running user and returns a link to open it.'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(createReport(req));
        }
        return results;
    }

    private static Result createReport(Request req) {
        Result result = new Result();
        result.isSuccess = false;
        try {
            if (req == null || String.isBlank(req.reportName) || String.isBlank(req.reportType)) {
                result.errorMessage = 'A report name and report type are required.';
                return result;
            }

            String format = String.isBlank(req.reportFormat) ? 'TABULAR' : req.reportFormat.trim().toUpperCase();
            if (format != 'TABULAR' && format != 'SUMMARY') {
                result.errorMessage = 'Only tabular and summary reports can be saved right now.';
                return result;
            }

            Map<String, Object> described = ReportAnalyticsClient.fetchReportType(req.reportType);
            Set<String> knownColumns = ReportAnalyticsClient.columnNames(ReportAnalyticsClient.allColumns(described));

            List<String> detailColumns = stringList(parseArray(req.detailColumnsJson, 'Columns'));
            List<Map<String, Object>> groupings = groupingList(parseArray(req.groupingsDownJson, 'Groupings'));
            List<Map<String, Object>> filters = filterList(parseArray(req.filtersJson, 'Filters'));
            List<Map<String, String>> standardFilters = standardFilterList(parseArray(req.standardFiltersJson, 'Standard filters'));

            Set<String> groupingNames = new Set<String>();
            for (Map<String, Object> grouping : groupings) {
                groupingNames.add((String) grouping.get('name'));
            }
            List<String> keptColumns = new List<String>();
            for (String column : detailColumns) {
                if (!groupingNames.contains(column)) {
                    keptColumns.add(column);
                }
            }
            detailColumns = keptColumns;

            requireKnown(knownColumns, detailColumns, 'column');
            requireKnown(knownColumns, new List<String>(groupingNames), 'grouping');
            for (Map<String, Object> filter : filters) {
                requireKnown(knownColumns, new List<String>{ (String) filter.get('column') }, 'filter');
            }

            if (format == 'SUMMARY' && groupings.isEmpty()) {
                result.errorMessage = 'A summary report needs at least one field to group by.';
                return result;
            }
            if (format == 'TABULAR' && detailColumns.isEmpty()) {
                result.errorMessage = 'Add at least one column to the report.';
                return result;
            }

            Map<String, Object> metadata = new Map<String, Object>{
                'name' => req.reportName.left(40),
                'reportFormat' => format,
                'reportType' => new Map<String, Object>{ 'type' => req.reportType },
                'detailColumns' => detailColumns,
                'reportFilters' => filters,
                'scope' => String.isBlank(req.scope) ? 'organization' : req.scope,
                'hasDetailRows' => true,
                'hasRecordCount' => true,
                'folderId' => UserInfo.getUserId()
            };
            if (format == 'SUMMARY') {
                metadata.put('groupingsDown', groupings);
                metadata.put('aggregates', new List<String>{ 'RowCount' });
                metadata.put('showGrandTotal', true);
                metadata.put('showSubtotals', true);
            }
            String dateColumn = String.isBlank(req.standardDateColumn)
                ? ReportAnalyticsClient.defaultDateColumn(described)
                : req.standardDateColumn;
            String duration = req.standardDateDuration == null ? '' : req.standardDateDuration.trim();
            Boolean userAskedForDates = String.isNotBlank(duration)
                && duration.toUpperCase() != 'NONE'
                && duration.toUpperCase() != 'CUSTOM';
            if (userAskedForDates && String.isNotBlank(dateColumn)) {
                metadata.put('standardDateFilter', new Map<String, Object>{
                    'column' => dateColumn,
                    'durationValue' => duration
                });
            } else if (String.isNotBlank(dateColumn)) {
                // Report types ship with a custom "from" date. Clear it unless the user asked for a range.
                metadata.put('standardDateFilter', new Map<String, Object>{
                    'column' => dateColumn,
                    'durationValue' => 'CUSTOM',
                    'startDate' => null,
                    'endDate' => null
                });
            }
            if (!standardFilters.isEmpty()) {
                metadata.put('standardFilters', standardFilters);
            }

            Object response;
            try {
                response = postReport(metadata);
            } catch (ReportAnalyticsClient.ReportAnalyticsException firstError) {
                if (!isNameConflict(firstError.getMessage())) {
                    throw firstError;
                }
                String datedName = req.reportName.left(28).trim() + ' ' + String.valueOf(Date.today());
                metadata.put('name', datedName.left(40));
                response = postReport(metadata);
            }

            Map<String, Object> body = (Map<String, Object>) response;
            Map<String, Object> attributes = (Map<String, Object>) body.get('attributes');
            Map<String, Object> saved = (Map<String, Object>) body.get('reportMetadata');
            String reportId = attributes == null ? null : (String) attributes.get('reportId');
            if (String.isBlank(reportId) && saved != null) {
                reportId = (String) saved.get('id');
            }
            result.reportId = reportId;
            result.reportName = saved != null && saved.get('name') != null
                ? (String) saved.get('name')
                : (String) metadata.get('name');
            result.reportUrl = ReportAnalyticsClient.lightningReportUrl(reportId);
            result.reportLink = '<a href="' + result.reportUrl + '">' + result.reportName + '</a>';
            result.isSuccess = true;
            result.errorMessage = '';
        } catch (Exception e) {
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    private static Object postReport(Map<String, Object> metadata) {
        return ReportAnalyticsClient.send(
            'POST',
            '/analytics/reports',
            JSON.serialize(new Map<String, Object>{ 'reportMetadata' => metadata })
        );
    }

    private static Boolean isNameConflict(String message) {
        String lower = message == null ? '' : message.toLowerCase();
        return lower.contains('already') || lower.contains('duplicate') || lower.contains('unique');
    }

    private static void requireKnown(Set<String> known, List<String> names, String role) {
        for (String name : names) {
            if (String.isBlank(name) || !known.contains(name)) {
                throw new ReportAnalyticsClient.ReportAnalyticsException(
                    'The ' + role + ' "' + name + '" is not on this report type. Use a column apiName from the describe result.'
                );
            }
        }
    }

    private static List<Object> parseArray(String raw, String label) {
        if (String.isBlank(raw)) {
            return new List<Object>();
        }
        Object parsed = JSON.deserializeUntyped(raw);
        if (!(parsed instanceof List<Object>)) {
            throw new ReportAnalyticsClient.ReportAnalyticsException(label + ' must be a JSON array.');
        }
        return (List<Object>) parsed;
    }

    private static List<String> stringList(List<Object> raw) {
        List<String> values = new List<String>();
        for (Object item : raw) {
            if (item != null) {
                values.add(String.valueOf(item));
            }
        }
        return values;
    }

    private static List<Map<String, Object>> groupingList(List<Object> raw) {
        List<Map<String, Object>> groupings = new List<Map<String, Object>>();
        for (Object item : raw) {
            String name;
            String granularity = 'None';
            if (item instanceof String) {
                name = (String) item;
            } else if (item instanceof Map<String, Object>) {
                Map<String, Object> row = (Map<String, Object>) item;
                name = row.get('name') == null ? null : String.valueOf(row.get('name'));
                if (String.isBlank(name) && row.get('column') != null) {
                    name = String.valueOf(row.get('column'));
                }
                if (row.get('dateGranularity') != null) {
                    granularity = String.valueOf(row.get('dateGranularity'));
                }
            }
            if (String.isBlank(name)) {
                continue;
            }
            groupings.add(new Map<String, Object>{
                'name' => name,
                'sortOrder' => 'Asc',
                'dateGranularity' => granularity
            });
        }
        return groupings;
    }

    private static List<Map<String, Object>> filterList(List<Object> raw) {
        List<Map<String, Object>> filters = new List<Map<String, Object>>();
        for (Object item : raw) {
            Map<String, Object> row = (Map<String, Object>) item;
            filters.add(new Map<String, Object>{
                'column' => String.valueOf(row.get('column')),
                'operator' => String.valueOf(row.get('operator')),
                'value' => row.get('value') == null ? '' : String.valueOf(row.get('value'))
            });
        }
        return filters;
    }

    private static List<Map<String, String>> standardFilterList(List<Object> raw) {
        List<Map<String, String>> filters = new List<Map<String, String>>();
        for (Object item : raw) {
            Map<String, Object> row = (Map<String, Object>) item;
            filters.add(new Map<String, String>{
                'name' => String.valueOf(row.get('name')),
                'value' => String.valueOf(row.get('value'))
            });
        }
        return filters;
    }

    public class Request {
        @InvocableVariable(label='Report Name' description='Short name for the saved report' required=true)
        public String reportName;

        @InvocableVariable(label='Report Type' description='Report type API name from the describe result' required=true)
        public String reportType;

        @InvocableVariable(label='Report Format' description='TABULAR or SUMMARY' required=true)
        public String reportFormat;

        @InvocableVariable(label='Detail Columns JSON' description='JSON array of column apiName values' required=true)
        public String detailColumnsJson;

        @InvocableVariable(label='Groupings JSON' description='JSON array of column apiName values to group by' required=false)
        public String groupingsDownJson;

        @InvocableVariable(label='Filters JSON' description='JSON array of column, operator, and value' required=false)
        public String filtersJson;

        @InvocableVariable(label='Scope' description='Report scope. Defaults to organization.' required=false)
        public String scope;

        @InvocableVariable(label='Standard Date Column' description='Date column for a standard date range, usually the defaultDateColumn' required=false)
        public String standardDateColumn;

        @InvocableVariable(label='Standard Date Duration' description='Duration such as THIS_FISCAL_QUARTER or THIS_MONTH' required=false)
        public String standardDateDuration;

        @InvocableVariable(label='Standard Filters JSON' description='JSON array of name and value, such as open/open' required=false)
        public String standardFiltersJson;
    }

    public class Result {
        @InvocableVariable(label='Is Success' description='Whether the report was saved')
        public Boolean isSuccess;

        @InvocableVariable(label='Report Id' description='Salesforce Id of the saved report')
        public String reportId;

        @InvocableVariable(label='Report Name' description='Name the report was saved with')
        public String reportName;

        @InvocableVariable(label='Report URL' description='Link that opens the saved report')
        public String reportUrl;

        @InvocableVariable(label='Report Link' description='HTML link the agent should send instead of a raw URL')
        public String reportLink;

        @InvocableVariable(label='Error Message' description='Plain-language error. Empty on success.')
        public String errorMessage;
    }
}

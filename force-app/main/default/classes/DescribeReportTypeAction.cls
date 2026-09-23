public with sharing class DescribeReportTypeAction {
    @InvocableMethod(
        label='Describe Report Type'
        description='Returns real columns, standard filters, and the default date column for a report type.'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(describeType(req));
        }
        return results;
    }

    private static Result describeType(Request req) {
        Result result = new Result();
        result.isSuccess = false;
        result.truncated = false;
        result.columnsJson = '{}';
        result.reportType = req == null ? '' : req.reportType;
        try {
            if (req == null || String.isBlank(req.reportType)) {
                result.errorMessage = 'Choose a report type before describing its columns.';
                return result;
            }

            Map<String, Object> payload = ReportAnalyticsClient.fetchReportType(req.reportType);
            List<Map<String, Object>> allColumns = ReportAnalyticsClient.allColumns(payload);
            List<Map<String, Object>> selected = ReportAnalyticsClient.columnsForAgent(allColumns, req.focusTerm);
            result.truncated = selected.size() < allColumns.size();
            result.columnsJson = JSON.serialize(new Map<String, Object>{
                'columns' => selected,
                'standardFilters' => ReportAnalyticsClient.standardFilters(payload),
                'defaultDateColumn' => ReportAnalyticsClient.defaultDateColumn(payload)
            });
            result.reportType = req.reportType;
            result.isSuccess = true;
            result.errorMessage = '';
        } catch (Exception e) {
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    public class Request {
        @InvocableVariable(label='Report Type' description='Report type API name, such as Opportunity' required=true)
        public String reportType;

        @InvocableVariable(label='Focus Term' description='Words from the request used to include extra columns, such as stage amount owner' required=false)
        public String focusTerm;
    }

    public class Result {
        @InvocableVariable(label='Columns JSON' description='JSON with columns, standard filters, and the default date column')
        public String columnsJson;

        @InvocableVariable(label='Truncated' description='True when some columns were left out')
        public Boolean truncated;

        @InvocableVariable(label='Is Success' description='Whether the report type was described')
        public Boolean isSuccess;

        @InvocableVariable(label='Report Type' description='Report type that was described')
        public String reportType;

        @InvocableVariable(label='Error Message' description='Plain-language error. Empty on success.')
        public String errorMessage;
    }
}
public with sharing class PricingTraceService {
    private static final Integer QUERY_LIMIT = 50;
    private static final Decimal SLOW_EXECUTION_THRESHOLD_MS = 3000;

    @AuraEnabled(cacheable=true)
    public static PricingTraceResponse getTrace(
        String recordId,
        String contextObjectApiName,
        Boolean forceDemoMode
    ) {
        if (forceDemoMode == true || String.isBlank(recordId)) {
            return buildDemoTrace(recordId, contextObjectApiName, 'Demo mode is enabled for portfolio preview.');
        }

        LiveTraceContext context = discoverLiveTrace(recordId);
        if (!context.hasSourceRecords()) {
            return buildEmptyTrace(recordId, contextObjectApiName, context);
        }

        return buildLiveTrace(recordId, contextObjectApiName, context);
    }

    @AuraEnabled
    public static ReplayResponse simulateReplay(
        String recordId,
        String contextObjectApiName,
        Decimal quantity,
        Boolean premiumSupport,
        String regionCode,
        Boolean forceDemoMode
    ) {
        Decimal requestedQuantity = quantity == null || quantity <= 0 ? 100 : quantity;
        String requestedRegion = String.isBlank(regionCode) ? 'NA' : regionCode.trim().toUpperCase();

        if (forceDemoMode == true || String.isBlank(recordId)) {
            return buildReplayResponse(
                2500,
                requestedQuantity,
                premiumSupport == true,
                requestedRegion,
                'Replay is running against the bundled demo pricing model.'
            );
        }

        LiveTraceContext context = discoverLiveTrace(recordId);
        if (!context.hasSourceRecords()) {
            ReplayResponse emptyReplay = new ReplayResponse();
            emptyReplay.mode = 'empty';
            emptyReplay.modeLabel = 'No Trace Data';
            emptyReplay.message =
                'No live pricing trace records were discovered for this record. Turn on demo mode to preview the replay flow.';
            emptyReplay.impacts = new List<PricingStepView>();
            emptyReplay.notices = new List<RiskFlagView>{
                buildRisk('info', 'Replay Needs Live Data', 'The starter only projects live replay scenarios when trace sources are available.')
            };
            return emptyReplay;
        }

        Decimal baseline = inferFinalPrice(context);
        if (baseline == null || baseline == 0) {
            baseline = 2500;
        }

        return buildReplayResponse(
            baseline,
            requestedQuantity,
            premiumSupport == true,
            requestedRegion,
            'Replay is using heuristic adjustments so the package remains deployable without hard Revenue Cloud API dependencies.'
        );
    }

    private static PricingTraceResponse buildLiveTrace(
        String recordId,
        String contextObjectApiName,
        LiveTraceContext context
    ) {
        PricingTraceResponse response = new PricingTraceResponse();
        response.mode = 'live';
        response.modeLabel = 'Live Trace';
        response.headline = 'Pricing Trace Explorer';
        response.contextObjectApiName = contextObjectApiName;
        response.contextRecordId = recordId;
        response.supportMessage =
            'Replay is scaffolded for /commerce/pricing/{objectName}/actions/calculate-price and currently ships with a heuristic simulation path.';
        response.sources = context.sources;
        response.timeline = new List<PricingStepView>();
        response.adjustments = new List<AdjustmentView>();
        response.tiers = new List<TierView>();
        response.procedureNodes = new List<ProcedureNodeView>();
        response.metrics = new List<MetricView>();
        response.riskFlags = new List<RiskFlagView>();
        response.canReplay = true;
        response.canUseDemo = true;

        List<SObject> rateCards = context.recordsByKey.get('rateCardEntry');
        List<SObject> quoteAdjustments = context.recordsByKey.get('rateAdjustment');
        List<SObject> orderAdjustments = context.recordsByKey.get('orderRateAdjustment');
        List<SObject> tiers = context.recordsByKey.get('priceAdjustmentTier');
        List<SObject> procedures = context.recordsByKey.get('procedureResolution');
        List<SObject> apiExecutions = context.recordsByKey.get('apiExecution');
        List<SObject> processExecutions = context.recordsByKey.get('processExecution');
        List<SObject> contractPrices = context.recordsByKey.get('contractItemPrice');
        Set<String> quoteAdjustmentIds = extractIds(quoteAdjustments);

        Decimal basePrice = firstMoney(rateCards, context.resolvedByKey.get('rateCardEntry'), 'amount');
        if (basePrice == null) {
            basePrice = firstMoney(contractPrices, context.resolvedByKey.get('contractItemPrice'), 'amount');
        }
        if (basePrice == null) {
            basePrice = 0;
        }

        Decimal runningTotal = basePrice;
        response.basePrice = basePrice;
        response.timeline.add(buildStep(
            'base',
            'Base Price',
            'Starting point recovered from the strongest available live source.',
            basePrice,
            runningTotal,
            'neutral',
            resolveSourceName(context, 'rateCardEntry', 'Base price unavailable, using fallback'),
            null
        ));

        Integer adjustmentIndex = 1;
        for (SObject record : combine(quoteAdjustments, orderAdjustments)) {
            String logicalKey = quoteAdjustmentIds.contains(String.valueOf(record.get('Id')))
                ? 'rateAdjustment'
                : 'orderRateAdjustment';
            ResolvedObjectConfig config = context.resolvedByKey.get(logicalKey);
            Decimal amount = toDecimal(readSemantic(record, config, 'amount'));
            if (amount == null) {
                continue;
            }

            runningTotal += amount;
            response.timeline.add(buildStep(
                'adj-' + adjustmentIndex,
                defaultString(stringValue(readSemantic(record, config, 'label')), 'Adjustment ' + adjustmentIndex),
                defaultString(stringValue(readSemantic(record, config, 'detail')), 'Live adjustment captured from pricing trace metadata.'),
                amount,
                runningTotal,
                amount >= 0 ? 'increase' : 'decrease',
                resolveSourceName(context, logicalKey, null),
                formatDate(readSemantic(record, config, 'timestamp'))
            ));

            AdjustmentView adjustment = new AdjustmentView();
            adjustment.key = 'adj-card-' + adjustmentIndex;
            adjustment.category = defaultString(stringValue(readSemantic(record, config, 'category')), config.label);
            adjustment.name = defaultString(stringValue(readSemantic(record, config, 'label')), 'Pricing Adjustment');
            adjustment.description = defaultString(
                stringValue(readSemantic(record, config, 'detail')),
                'Recovered from dynamic Revenue Cloud trace metadata.'
            );
            adjustment.amount = amount;
            adjustment.direction = amount >= 0 ? 'increase' : 'decrease';
            adjustment.source = resolveSourceName(context, logicalKey, null);
            adjustment.overridden = toBoolean(readSemantic(record, config, 'overrideFlag'));
            response.adjustments.add(adjustment);
            adjustmentIndex++;
        }

        response.finalPrice = runningTotal;
        response.timeline.add(buildStep(
            'final',
            'Final Price',
            'Net result after applying the recovered pricing adjustments.',
            response.finalPrice,
            response.finalPrice,
            'neutral',
            'Calculated',
            null
        ));

        response.oldPrice = firstMoney(contractPrices, context.resolvedByKey.get('contractItemPrice'), 'amount');
        if (response.oldPrice != null) {
            response.deltaAmount = response.finalPrice - response.oldPrice;
        } else {
            response.deltaAmount = response.finalPrice - response.basePrice;
        }

        Integer tierIndex = 1;
        for (SObject record : tiers) {
            ResolvedObjectConfig config = context.resolvedByKey.get('priceAdjustmentTier');
            TierView tier = new TierView();
            tier.key = 'tier-' + tierIndex;
            tier.tierName = defaultString(stringValue(readSemantic(record, config, 'label')), 'Tier ' + tierIndex);
            tier.rangeLabel = buildRangeLabel(
                toDecimal(readSemantic(record, config, 'rangeStart')),
                toDecimal(readSemantic(record, config, 'rangeEnd'))
            );
            tier.rate = toDecimal(readSemantic(record, config, 'rate'));
            tier.appliedQuantity = toDecimal(readSemantic(record, config, 'quantity'));
            tier.appliedValue = toDecimal(readSemantic(record, config, 'amount'));
            response.tiers.add(tier);
            tierIndex++;
        }

        Integer procedureIndex = 1;
        for (SObject record : procedures) {
            ResolvedObjectConfig config = context.resolvedByKey.get('procedureResolution');
            ProcedureNodeView node = new ProcedureNodeView();
            node.key = 'proc-' + procedureIndex;
            node.label = defaultString(stringValue(readSemantic(record, config, 'label')), 'Pricing Procedure Decision');
            node.detail = defaultString(
                stringValue(readSemantic(record, config, 'detail')),
                'Decision metadata captured from Revenue Cloud procedure resolution records.'
            );
            node.outcome = defaultString(stringValue(readSemantic(record, config, 'status')), 'Resolved');
            node.depth = 0;
            node.matched = !String.isBlank(node.outcome) && node.outcome.toLowerCase().contains('fail') == false;
            response.procedureNodes.add(node);
            procedureIndex++;
        }

        Decimal totalDuration = sumDurations(apiExecutions, context.resolvedByKey.get('apiExecution'))
            + sumDurations(processExecutions, context.resolvedByKey.get('processExecution'));

        response.metrics.add(buildMetric('duration', 'Execution Time', formatCurrencyless(totalDuration) + ' ms', totalDuration > SLOW_EXECUTION_THRESHOLD_MS ? 'warning' : 'ok'));
        response.metrics.add(buildMetric('procedures', 'Procedure Decisions', String.valueOf(response.procedureNodes.size()), response.procedureNodes.isEmpty() ? 'warning' : 'ok'));
        response.metrics.add(buildMetric('adjustments', 'Adjustments', String.valueOf(response.adjustments.size()), response.adjustments.isEmpty() ? 'warning' : 'ok'));
        response.metrics.add(buildMetric('sources', 'Live Sources', String.valueOf(countAvailableSources(response.sources)) + '/' + String.valueOf(response.sources.size()), 'ok'));

        if (processExecutions.size() > 1 || apiExecutions.size() > 1) {
            response.riskFlags.add(buildRisk(
                'warning',
                'Multiple Pricing Executions',
                'More than one pricing execution was discovered for this record. Analysts should verify which run is authoritative.'
            ));
        }

        if (totalDuration > SLOW_EXECUTION_THRESHOLD_MS) {
            response.riskFlags.add(buildRisk(
                'warning',
                'Slow Pricing Path',
                'Recovered execution duration exceeded the 3 second threshold. This is a candidate for recipe or criteria optimization.'
            ));
        }

        if (response.tiers.size() > 1 && hasOverlappingTiers(response.tiers)) {
            response.riskFlags.add(buildRisk(
                'danger',
                'Tier Overlap Detected',
                'At least two recovered pricing tiers overlap by quantity range, which can lead to difficult-to-explain pricing outcomes.'
            ));
        }

        if (rateCards == null || rateCards.isEmpty()) {
            response.riskFlags.add(buildRisk(
                'info',
                'Base Price Was Inferred',
                'No rate card entry was found for the selected record, so the baseline came from the next strongest source.'
            ));
        }

        if (response.procedureNodes.isEmpty()) {
            response.riskFlags.add(buildRisk(
                'info',
                'Procedure Trace Is Thin',
                'The pricing result is visible, but decision-level procedure resolution records were not discovered.'
            ));
        }

        response.summary = buildSummary(response.oldPrice, response.finalPrice, response.deltaAmount, response.adjustments.size());
        return response;
    }

    private static PricingTraceResponse buildDemoTrace(
        String recordId,
        String contextObjectApiName,
        String note
    ) {
        PricingTraceResponse response = new PricingTraceResponse();
        response.mode = 'demo';
        response.modeLabel = 'Demo Trace';
        response.headline = 'Pricing Trace Explorer';
        response.contextObjectApiName = contextObjectApiName;
        response.contextRecordId = recordId;
        response.basePrice = 2500;
        response.oldPrice = 2500;
        response.finalPrice = 2950;
        response.deltaAmount = 450;
        response.summary = 'Old MRR $2,500 to New MRR $2,950 driven by usage tier crossover, premium support, and discount retirement.';
        response.supportMessage =
            'This demo mirrors the Revenue Cloud pricing data model and keeps replay deployable without a managed-package compile-time dependency.';
        response.canReplay = true;
        response.canUseDemo = true;

        response.timeline = new List<PricingStepView>{
            buildStep('base', 'Base Contract Price', 'Starting contracted recurring price.', 2500, 2500, 'neutral', 'Contract Item Price', '2026-03-03 09:00'),
            buildStep('support', 'Premium Support', 'Attribute-driven uplift for support level = Premium.', 200, 2700, 'increase', 'Quote Line Rate Adjustment', '2026-03-03 09:00'),
            buildStep('tier', 'Usage Threshold Crossover', 'Quantity crossed the 100 unit threshold and triggered the next tier.', 300, 3000, 'increase', 'Price Adjustment Tier', '2026-03-03 09:00'),
            buildStep('legacy', 'Legacy Bundle Incentive', 'Existing discount still applied from the prior commercial package.', -50, 2950, 'decrease', 'Quote Line Rate Adjustment', '2026-03-03 09:00'),
            buildStep('final', 'Final Price', 'Net result after all pricing procedures and adjustments.', 2950, 2950, 'neutral', 'Calculated', '2026-03-03 09:00')
        };

        response.adjustments = new List<AdjustmentView>{
            buildAdjustment('adj-1', 'Attribute Adjustment', 'Premium Support', 'High-touch support plan for enterprise SLA.', 200, 'increase', 'Quote Line Rate Adjustment', false),
            buildAdjustment('adj-2', 'Tier Adjustment', 'Usage Threshold Crossover', 'Volume moved from Tier 2 to Tier 3 for 20 units.', 300, 'increase', 'Price Adjustment Tier', false),
            buildAdjustment('adj-3', 'Discount Adjustment', 'Legacy Bundle Incentive', 'Bundle incentive partially offsets the new uplift.', -50, 'decrease', 'Quote Line Rate Adjustment', true)
        };

        response.tiers = new List<TierView>{
            buildTier('tier-1', 'Tier 1', '1 - 100', 25, 100, 2500),
            buildTier('tier-2', 'Tier 2', '101 - 120', 15, 20, 300)
        };

        response.procedureNodes = new List<ProcedureNodeView>{
            buildProcedureNode('node-1', 'IF Product Family = Telecom', 'Route into the telecom pricing plan.', 'Matched', 0, true),
            buildProcedureNode('node-2', 'THEN Apply Usage Pricing Recipe', 'Base recurring price and tier evaluation execute.', 'Applied', 1, true),
            buildProcedureNode('node-3', 'IF Quantity > 100', 'Escalate to the Tier 3 uplift logic.', 'Matched', 2, true),
            buildProcedureNode('node-4', 'IF Support Level = Premium', 'Inject premium support surcharge.', 'Matched', 2, true),
            buildProcedureNode('node-5', 'IF Legacy Discount Still Eligible', 'Commercial override remains active until renewal.', 'Partially Matched', 1, true)
        };

        response.metrics = new List<MetricView>{
            buildMetric('duration', 'Execution Time', '3400 ms', 'warning'),
            buildMetric('procedures', 'Procedure Decisions', '5', 'ok'),
            buildMetric('adjustments', 'Adjustments', '3', 'ok'),
            buildMetric('sources', 'Live Sources', '5/7', 'ok')
        };

        response.riskFlags = new List<RiskFlagView>{
            buildRisk('warning', 'Slow Pricing Path', 'The simulated execution exceeded the 3 second target. Bundle and criteria pruning would be the next optimization step.'),
            buildRisk('info', 'Overridden Discount', 'A legacy incentive remains active and can surprise sellers during amendments.'),
            buildRisk('info', 'Demo Dataset', note)
        };

        response.sources = new List<SourceStatusView>{
            buildSource('PricingAPIExecution', true, 1, 'Available in demo'),
            buildSource('PricingProcessExecution', true, 1, 'Available in demo'),
            buildSource('PricingProcedureResolution', true, 5, 'Available in demo'),
            buildSource('QuoteLineRateAdjustment', true, 2, 'Available in demo'),
            buildSource('PriceAdjustmentTier', true, 2, 'Available in demo'),
            buildSource('ContractItemPrice', true, 1, 'Available in demo'),
            buildSource('OrderItemRateAdjustment', false, 0, 'Not used in the demo scenario')
        };

        return response;
    }

    private static PricingTraceResponse buildEmptyTrace(
        String recordId,
        String contextObjectApiName,
        LiveTraceContext context
    ) {
        PricingTraceResponse response = new PricingTraceResponse();
        response.mode = 'empty';
        response.modeLabel = 'Awaiting Trace';
        response.headline = 'Pricing Trace Explorer';
        response.contextObjectApiName = contextObjectApiName;
        response.contextRecordId = recordId;
        response.summary = 'No related pricing trace records were discovered for this record yet.';
        response.supportMessage =
            'If you want a recruiter-facing preview, switch to demo mode. On a live org, this state usually means pricing has not executed or the object bindings need tuning.';
        response.timeline = new List<PricingStepView>();
        response.adjustments = new List<AdjustmentView>();
        response.tiers = new List<TierView>();
        response.procedureNodes = new List<ProcedureNodeView>();
        response.metrics = new List<MetricView>{
            buildMetric('sources', 'Reachable Sources', String.valueOf(countAvailableSources(context.sources)) + '/' + String.valueOf(context.sources.size()), 'ok'),
            buildMetric('records', 'Recovered Records', '0', 'warning')
        };
        response.riskFlags = new List<RiskFlagView>{
            buildRisk('info', 'No Trace Rows Found', 'Revenue Cloud trace objects were either absent, inaccessible, or did not contain rows linked to this record.'),
            buildRisk('info', 'Demo Mode Available', 'Use the built-in demo to preview the full experience without wiring the org-specific pricing endpoint.')
        };
        response.sources = context.sources;
        response.canReplay = false;
        response.canUseDemo = true;
        return response;
    }

    private static LiveTraceContext discoverLiveTrace(String recordId) {
        LiveTraceContext context = new LiveTraceContext();
        Set<String> anchorIds = new Set<String>();

        for (TraceObjectConfig config : orderedConfigs()) {
            ResolvedObjectConfig resolved = resolveConfig(config);
            context.resolvedByKey.put(config.key, resolved);

            SourceStatusView source = new SourceStatusView();
            source.logicalName = config.label;
            source.objectApiName = resolved == null ? defaultCandidate(config.objectCandidates) : resolved.objectApiName;
            source.available = resolved != null;
            source.note = resolved == null ? 'Object not available or not accessible in this org.' : 'Resolved dynamically at runtime.';

            if (resolved == null) {
                context.sources.add(source);
                context.recordsByKey.put(config.key, new List<SObject>());
                continue;
            }

            List<SObject> records = queryRecords(resolved, recordId, anchorIds, source);
            source.recordCount = records.size();
            context.sources.add(source);
            context.recordsByKey.put(config.key, records);

            for (SObject record : records) {
                context.anchorIds.add(String.valueOf(record.get('Id')));
            }
            if (config.key == 'apiExecution' || config.key == 'processExecution') {
                anchorIds.addAll(extractIds(records));
            }
        }

        return context;
    }

    private static List<SObject> queryRecords(
        ResolvedObjectConfig config,
        String recordId,
        Set<String> anchorIds,
        SourceStatusView source
    ) {
        List<String> filters = new List<String>();
        Boolean hasRecordId = isLikelySalesforceId(recordId);

        if (hasRecordId) {
            for (String relationField : config.relationFields) {
                filters.add(relationField + ' = :recordId');
            }
        }

        if (!anchorIds.isEmpty()) {
            for (String anchorField : config.anchorFields) {
                filters.add(anchorField + ' IN :anchorIds');
            }
        }

        if (filters.isEmpty()) {
            source.note = 'No filterable relation fields were found for this object in the current org.';
            return new List<SObject>();
        }

        String soql = 'SELECT ' + String.join(config.selectFields, ', ')
            + ' FROM ' + config.objectApiName
            + ' WHERE (' + String.join(filters, ' OR ') + ')';

        if (!String.isBlank(config.orderField)) {
            soql += ' ORDER BY ' + config.orderField + ' DESC';
        }

        soql += ' LIMIT ' + QUERY_LIMIT;

        try {
            List<SObject> records = Database.query(soql);
            if (!records.isEmpty()) {
                records = Security.stripInaccessible(AccessType.READABLE, records).getRecords();
            }
            return records;
        } catch (Exception queryException) {
            source.note = 'Query failed at runtime: ' + queryException.getMessage();
            return new List<SObject>();
        }
    }

    private static ResolvedObjectConfig resolveConfig(TraceObjectConfig config) {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        for (String objectApiName : config.objectCandidates) {
            if (!globalDescribe.containsKey(objectApiName)) {
                continue;
            }

            Schema.DescribeSObjectResult describe = globalDescribe.get(objectApiName).getDescribe();
            if (!describe.isAccessible()) {
                continue;
            }

            Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
            ResolvedObjectConfig resolved = new ResolvedObjectConfig();
            resolved.key = config.key;
            resolved.label = config.label;
            resolved.objectApiName = objectApiName;
            resolved.selectFields.add('Id');

            for (String relationField : config.relationFields) {
                Schema.DescribeFieldResult fieldDescribe = describeField(fieldMap, relationField);
                if (fieldDescribe != null && fieldDescribe.isAccessible() && fieldDescribe.isFilterable()) {
                    resolved.relationFields.add(relationField);
                    addSelectField(resolved.selectFields, relationField);
                }
            }

            for (String anchorField : config.anchorFields) {
                Schema.DescribeFieldResult fieldDescribe = describeField(fieldMap, anchorField);
                if (fieldDescribe != null && fieldDescribe.isAccessible() && fieldDescribe.isFilterable()) {
                    resolved.anchorFields.add(anchorField);
                    addSelectField(resolved.selectFields, anchorField);
                }
            }

            for (String semantic : config.semanticCandidates.keySet()) {
                String selectedField = firstReadableField(fieldMap, config.semanticCandidates.get(semantic));
                if (!String.isBlank(selectedField)) {
                    resolved.fieldBySemantic.put(semantic, selectedField);
                    addSelectField(resolved.selectFields, selectedField);

                    if (semantic == 'timestamp' || semantic == 'sequence') {
                        Schema.DescribeFieldResult fieldDescribe = describeField(fieldMap, selectedField);
                        if (fieldDescribe != null && fieldDescribe.isSortable() && String.isBlank(resolved.orderField)) {
                            resolved.orderField = selectedField;
                        }
                    }
                }
            }

            if (String.isBlank(resolved.orderField) && describe.fields.getMap().containsKey('CreatedDate')) {
                Schema.DescribeFieldResult createdDateDescribe = describe.fields.getMap().get('CreatedDate').getDescribe();
                if (createdDateDescribe.isAccessible() && createdDateDescribe.isSortable()) {
                    resolved.orderField = 'CreatedDate';
                    addSelectField(resolved.selectFields, 'CreatedDate');
                }
            }

            return resolved;
        }

        return null;
    }

    private static List<TraceObjectConfig> orderedConfigs() {
        return new List<TraceObjectConfig>{
            new TraceObjectConfig(
                'apiExecution',
                'Pricing API Execution',
                new List<String>{ 'PricingAPIExecution', 'PricingAPIExecution__c' },
                commonRelationFields(),
                new List<String>(),
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'ExecutionName', 'ExecutionName__c' },
                    'status' => new List<String>{ 'Status', 'Status__c', 'State', 'State__c' },
                    'duration' => new List<String>{ 'ExecutionDurationInMs', 'ExecutionDurationInMs__c', 'DurationMs', 'DurationMs__c', 'TotalExecutionTime', 'TotalExecutionTime__c' },
                    'timestamp' => new List<String>{ 'StartTime', 'StartTime__c', 'CreatedDate' },
                    'detail' => new List<String>{ 'Message', 'Message__c', 'Description', 'Description__c' },
                    'amount' => new List<String>{ 'TotalAmount', 'TotalAmount__c', 'CalculatedAmount', 'CalculatedAmount__c', 'FinalAmount', 'FinalAmount__c' }
                }
            ),
            new TraceObjectConfig(
                'processExecution',
                'Pricing Process Execution',
                new List<String>{ 'PricingProcessExecution', 'PricingProcessExecution__c' },
                commonRelationFields(),
                new List<String>{ 'PricingAPIExecutionId', 'PricingAPIExecutionId__c' },
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'ProcessName', 'ProcessName__c' },
                    'status' => new List<String>{ 'Status', 'Status__c', 'State', 'State__c' },
                    'duration' => new List<String>{ 'ExecutionDurationInMs', 'ExecutionDurationInMs__c', 'DurationMs', 'DurationMs__c' },
                    'timestamp' => new List<String>{ 'StartTime', 'StartTime__c', 'CreatedDate' },
                    'detail' => new List<String>{ 'ResolutionSummary', 'ResolutionSummary__c', 'Description', 'Description__c' },
                    'sequence' => new List<String>{ 'StepNumber', 'StepNumber__c', 'Sequence', 'Sequence__c' }
                }
            ),
            new TraceObjectConfig(
                'procedureResolution',
                'Pricing Procedure Resolution',
                new List<String>{ 'PricingProcedureResolution', 'PricingProcedureResolution__c' },
                commonRelationFields(),
                new List<String>{ 'PricingProcessExecutionId', 'PricingProcessExecutionId__c', 'PricingAPIExecutionId', 'PricingAPIExecutionId__c' },
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'ProcedureName', 'ProcedureName__c', 'CriterionName', 'CriterionName__c' },
                    'status' => new List<String>{ 'Status', 'Status__c', 'ResolutionStatus', 'ResolutionStatus__c', 'Outcome', 'Outcome__c' },
                    'timestamp' => new List<String>{ 'CreatedDate' },
                    'detail' => new List<String>{ 'ResolutionMessage', 'ResolutionMessage__c', 'Description', 'Description__c', 'ConditionText', 'ConditionText__c' },
                    'sequence' => new List<String>{ 'Sequence', 'Sequence__c', 'SortOrder', 'SortOrder__c' }
                }
            ),
            new TraceObjectConfig(
                'rateCardEntry',
                'Quote Line Rate Card Entry',
                new List<String>{ 'QuoteLineRateCardEntry', 'QuoteLineRateCardEntry__c' },
                commonRelationFields(),
                new List<String>{ 'PricingProcessExecutionId', 'PricingProcessExecutionId__c' },
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'RateCardName', 'RateCardName__c' },
                    'detail' => new List<String>{ 'RateCardEntryName', 'RateCardEntryName__c', 'Description', 'Description__c' },
                    'amount' => new List<String>{ 'Amount', 'Amount__c', 'ChargeAmount', 'ChargeAmount__c', 'UnitPrice', 'UnitPrice__c' },
                    'rate' => new List<String>{ 'Rate', 'Rate__c', 'UnitPrice', 'UnitPrice__c' },
                    'quantity' => new List<String>{ 'Quantity', 'Quantity__c', 'AppliedQuantity', 'AppliedQuantity__c' },
                    'timestamp' => new List<String>{ 'CreatedDate' }
                }
            ),
            new TraceObjectConfig(
                'rateAdjustment',
                'Quote Line Rate Adjustment',
                new List<String>{ 'QuoteLineRateAdjustment', 'QuoteLineRateAdjustment__c' },
                commonRelationFields(),
                new List<String>{ 'PricingProcessExecutionId', 'PricingProcessExecutionId__c', 'PricingAPIExecutionId', 'PricingAPIExecutionId__c' },
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'AdjustmentName', 'AdjustmentName__c', 'RuleName', 'RuleName__c' },
                    'category' => new List<String>{ 'AdjustmentType', 'AdjustmentType__c', 'Category', 'Category__c' },
                    'detail' => new List<String>{ 'AdjustmentReason', 'AdjustmentReason__c', 'Description', 'Description__c' },
                    'amount' => new List<String>{ 'Amount', 'Amount__c', 'AdjustmentAmount', 'AdjustmentAmount__c', 'DeltaAmount', 'DeltaAmount__c' },
                    'overrideFlag' => new List<String>{ 'IsOverridden', 'IsOverridden__c', 'WasOverridden', 'WasOverridden__c' },
                    'timestamp' => new List<String>{ 'CreatedDate' },
                    'sequence' => new List<String>{ 'Sequence', 'Sequence__c', 'SortOrder', 'SortOrder__c' }
                }
            ),
            new TraceObjectConfig(
                'orderRateAdjustment',
                'Order Item Rate Adjustment',
                new List<String>{ 'OrderItemRateAdjustment', 'OrderItemRateAdjustment__c' },
                new List<String>{ 'OrderItemId', 'OrderItemId__c', 'RelatedRecordId', 'RelatedRecordId__c', 'TargetRecordId', 'TargetRecordId__c' },
                new List<String>{ 'PricingProcessExecutionId', 'PricingProcessExecutionId__c', 'PricingAPIExecutionId', 'PricingAPIExecutionId__c' },
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'AdjustmentName', 'AdjustmentName__c' },
                    'category' => new List<String>{ 'AdjustmentType', 'AdjustmentType__c', 'Category', 'Category__c' },
                    'detail' => new List<String>{ 'AdjustmentReason', 'AdjustmentReason__c', 'Description', 'Description__c' },
                    'amount' => new List<String>{ 'Amount', 'Amount__c', 'AdjustmentAmount', 'AdjustmentAmount__c' },
                    'overrideFlag' => new List<String>{ 'IsOverridden', 'IsOverridden__c', 'WasOverridden', 'WasOverridden__c' },
                    'timestamp' => new List<String>{ 'CreatedDate' },
                    'sequence' => new List<String>{ 'Sequence', 'Sequence__c', 'SortOrder', 'SortOrder__c' }
                }
            ),
            new TraceObjectConfig(
                'priceAdjustmentTier',
                'Price Adjustment Tier',
                new List<String>{ 'PriceAdjustmentTier', 'PriceAdjustmentTier__c' },
                commonRelationFields(),
                new List<String>{ 'QuoteLineRateAdjustmentId', 'QuoteLineRateAdjustmentId__c', 'PricingProcessExecutionId', 'PricingProcessExecutionId__c' },
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'TierName', 'TierName__c' },
                    'amount' => new List<String>{ 'Amount', 'Amount__c', 'AppliedAmount', 'AppliedAmount__c', 'Value', 'Value__c' },
                    'rate' => new List<String>{ 'Rate', 'Rate__c', 'AdjustmentRate', 'AdjustmentRate__c' },
                    'quantity' => new List<String>{ 'AppliedQuantity', 'AppliedQuantity__c', 'Quantity', 'Quantity__c' },
                    'rangeStart' => new List<String>{ 'RangeStart', 'RangeStart__c', 'LowerBound', 'LowerBound__c', 'FromQuantity', 'FromQuantity__c' },
                    'rangeEnd' => new List<String>{ 'RangeEnd', 'RangeEnd__c', 'UpperBound', 'UpperBound__c', 'ToQuantity', 'ToQuantity__c' },
                    'timestamp' => new List<String>{ 'CreatedDate' }
                }
            ),
            new TraceObjectConfig(
                'contractItemPrice',
                'Contract Item Price',
                new List<String>{ 'ContractItemPrice', 'ContractItemPrice__c' },
                new List<String>{ 'ContractItemId', 'ContractItemId__c', 'RelatedRecordId', 'RelatedRecordId__c', 'TargetRecordId', 'TargetRecordId__c' },
                new List<String>(),
                new Map<String, List<String>>{
                    'label' => new List<String>{ 'Name', 'PriceName', 'PriceName__c' },
                    'detail' => new List<String>{ 'Description', 'Description__c' },
                    'amount' => new List<String>{ 'Amount', 'Amount__c', 'NetAmount', 'NetAmount__c', 'RecurringAmount', 'RecurringAmount__c' },
                    'timestamp' => new List<String>{ 'CreatedDate' }
                }
            )
        };
    }

    private static ReplayResponse buildReplayResponse(
        Decimal baseline,
        Decimal requestedQuantity,
        Boolean premiumSupport,
        String regionCode,
        String message
    ) {
        Decimal quantityDelta = requestedQuantity <= 100 ? 0 : (requestedQuantity - 100) * 15;
        Decimal supportDelta = premiumSupport ? 200 : 0;
        Decimal regionDelta = 0;

        if (regionCode == 'EMEA') {
            regionDelta = 75;
        } else if (regionCode == 'APAC') {
            regionDelta = 40;
        }

        Decimal projectedPrice = baseline + quantityDelta + supportDelta + regionDelta;

        ReplayResponse replay = new ReplayResponse();
        replay.mode = 'simulation';
        replay.modeLabel = 'Replay Projection';
        replay.projectedPrice = projectedPrice;
        replay.deltaAmount = projectedPrice - baseline;
        replay.message = message;
        replay.impacts = new List<PricingStepView>{
            buildStep('replay-base', 'Current Price', 'Baseline used for the replay projection.', baseline, baseline, 'neutral', 'Trace Baseline', null),
            buildStep('replay-qty', 'Quantity Effect', 'Heuristic uplift above 100 units.', quantityDelta, baseline + quantityDelta, quantityDelta >= 0 ? 'increase' : 'decrease', 'Replay Engine', null),
            buildStep('replay-support', 'Premium Support', premiumSupport ? 'Support uplift applied.' : 'No premium support uplift.', supportDelta, baseline + quantityDelta + supportDelta, supportDelta >= 0 ? 'increase' : 'decrease', 'Replay Engine', null),
            buildStep('replay-region', 'Regional Price Context', 'Regional heuristic based on the selected market.', regionDelta, projectedPrice, regionDelta >= 0 ? 'increase' : 'decrease', 'Replay Engine', null)
        };
        replay.notices = new List<RiskFlagView>{
            buildRisk('info', 'Heuristic Replay', 'This starter keeps the UI and service contract ready for headless pricing, but the shipped replay math is intentionally package-agnostic.')
        };

        if (requestedQuantity > 250) {
            replay.notices.add(buildRisk('warning', 'Large Quantity Change', 'A large quantity jump is often where overlapping tiers or capped discounts become difficult to reason about.'));
        }

        return replay;
    }

    private static Decimal inferFinalPrice(LiveTraceContext context) {
        List<SObject> rateCards = context.recordsByKey.get('rateCardEntry');
        List<SObject> contractPrices = context.recordsByKey.get('contractItemPrice');
        Set<String> quoteAdjustmentIds = extractIds(context.recordsByKey.get('rateAdjustment'));
        Decimal runningTotal = firstMoney(rateCards, context.resolvedByKey.get('rateCardEntry'), 'amount');
        if (runningTotal == null) {
            runningTotal = firstMoney(contractPrices, context.resolvedByKey.get('contractItemPrice'), 'amount');
        }
        if (runningTotal == null) {
            runningTotal = 0;
        }

        for (SObject adjustment : combine(context.recordsByKey.get('rateAdjustment'), context.recordsByKey.get('orderRateAdjustment'))) {
            String logicalKey = quoteAdjustmentIds.contains(String.valueOf(adjustment.get('Id')))
                ? 'rateAdjustment'
                : 'orderRateAdjustment';
            runningTotal += defaultDecimal(toDecimal(readSemantic(adjustment, context.resolvedByKey.get(logicalKey), 'amount')));
        }

        return runningTotal;
    }

    private static Boolean hasOverlappingTiers(List<TierView> tiers) {
        List<TierView> sortedTiers = new List<TierView>();
        sortedTiers.addAll(tiers);
        sortedTiers.sort();

        Decimal priorEnd;
        for (TierView tier : sortedTiers) {
            Decimal startValue = extractRangeStart(tier.rangeLabel);
            Decimal endValue = extractRangeEnd(tier.rangeLabel);
            if (startValue == null || endValue == null) {
                continue;
            }
            if (priorEnd != null && startValue <= priorEnd) {
                return true;
            }
            priorEnd = endValue;
        }
        return false;
    }

    private static Decimal extractRangeStart(String rangeLabel) {
        if (String.isBlank(rangeLabel) || !rangeLabel.contains('-')) {
            return null;
        }
        List<String> parts = rangeLabel.replace(' ', '').split('-');
        return parts.isEmpty() ? null : toDecimal(parts[0]);
    }

    private static Decimal extractRangeEnd(String rangeLabel) {
        if (String.isBlank(rangeLabel) || !rangeLabel.contains('-')) {
            return null;
        }
        List<String> parts = rangeLabel.replace(' ', '').split('-');
        return parts.size() < 2 ? null : toDecimal(parts[1]);
    }

    private static Decimal sumDurations(List<SObject> records, ResolvedObjectConfig config) {
        Decimal total = 0;
        if (records == null || config == null) {
            return total;
        }
        for (SObject record : records) {
            total += defaultDecimal(toDecimal(readSemantic(record, config, 'duration')));
        }
        return total;
    }

    private static List<SObject> combine(List<SObject> left, List<SObject> right) {
        List<SObject> combined = new List<SObject>();
        if (left != null) {
            combined.addAll(left);
        }
        if (right != null) {
            combined.addAll(right);
        }
        return combined;
    }

    private static Decimal firstMoney(List<SObject> records, ResolvedObjectConfig config, String semantic) {
        if (records == null || config == null) {
            return null;
        }
        for (SObject record : records) {
            Decimal value = toDecimal(readSemantic(record, config, semantic));
            if (value != null) {
                return value;
            }
        }
        return null;
    }

    private static Object readSemantic(SObject record, ResolvedObjectConfig config, String semantic) {
        if (record == null || config == null || !config.fieldBySemantic.containsKey(semantic)) {
            return null;
        }
        return record.get(config.fieldBySemantic.get(semantic));
    }

    private static String resolveSourceName(LiveTraceContext context, String logicalKey, String fallback) {
        if (context == null || !context.resolvedByKey.containsKey(logicalKey) || context.resolvedByKey.get(logicalKey) == null) {
            return defaultString(fallback, 'Unknown Source');
        }
        return context.resolvedByKey.get(logicalKey).label;
    }

    private static Integer countAvailableSources(List<SourceStatusView> sources) {
        Integer count = 0;
        for (SourceStatusView source : sources) {
            if (source.available) {
                count++;
            }
        }
        return count;
    }

    private static Set<String> extractIds(List<SObject> records) {
        Set<String> ids = new Set<String>();
        if (records == null) {
            return ids;
        }
        for (SObject record : records) {
            ids.add(String.valueOf(record.get('Id')));
        }
        return ids;
    }

    private static Boolean isLikelySalesforceId(String value) {
        return !String.isBlank(value) && (value.length() == 15 || value.length() == 18);
    }

    private static String firstReadableField(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
        for (String candidate : candidates) {
            Schema.DescribeFieldResult describe = describeField(fieldMap, candidate);
            if (describe != null && describe.isAccessible()) {
                return candidate;
            }
        }
        return null;
    }

    private static Schema.DescribeFieldResult describeField(Map<String, Schema.SObjectField> fieldMap, String fieldName) {
        if (!fieldMap.containsKey(fieldName)) {
            return null;
        }
        return fieldMap.get(fieldName).getDescribe();
    }

    private static void addSelectField(List<String> selectFields, String fieldName) {
        if (!String.isBlank(fieldName) && !selectFields.contains(fieldName)) {
            selectFields.add(fieldName);
        }
    }

    private static List<String> commonRelationFields() {
        return new List<String>{
            'RelatedRecordId',
            'RelatedRecordId__c',
            'TargetRecordId',
            'TargetRecordId__c',
            'SourceObjectId',
            'SourceObjectId__c',
            'QuoteLineId',
            'QuoteLineId__c',
            'OrderItemId',
            'OrderItemId__c',
            'ContractItemId',
            'ContractItemId__c'
        };
    }

    private static String defaultCandidate(List<String> candidates) {
        return candidates.isEmpty() ? 'UnknownObject' : candidates[0];
    }

    private static String buildRangeLabel(Decimal startValue, Decimal endValue) {
        if (startValue == null && endValue == null) {
            return 'Not available';
        }
        if (startValue == null) {
            return '<= ' + formatCurrencyless(endValue);
        }
        if (endValue == null) {
            return formatCurrencyless(startValue) + '+';
        }
        return formatCurrencyless(startValue) + ' - ' + formatCurrencyless(endValue);
    }

    private static String buildSummary(Decimal oldPrice, Decimal finalPrice, Decimal deltaAmount, Integer adjustmentCount) {
        String deltaDirection = deltaAmount == null || deltaAmount == 0 ? 'flat' : (deltaAmount > 0 ? 'increase' : 'decrease');
        if (oldPrice != null) {
            return 'Previous price ' + formatCurrency(oldPrice) + ', current price ' + formatCurrency(finalPrice)
                + ', ' + deltaDirection + ' of ' + formatCurrency(deltaAmount) + ' across ' + adjustmentCount + ' recovered adjustments.';
        }
        return 'Current price ' + formatCurrency(finalPrice) + ' reconstructed from ' + adjustmentCount + ' recovered pricing adjustments.';
    }

    private static PricingStepView buildStep(
        String key,
        String label,
        String detail,
        Decimal amount,
        Decimal runningTotal,
        String direction,
        String source,
        String timestampLabel
    ) {
        PricingStepView step = new PricingStepView();
        step.key = key;
        step.label = label;
        step.detail = detail;
        step.amount = amount;
        step.runningTotal = runningTotal;
        step.direction = direction;
        step.source = source;
        step.timestampLabel = timestampLabel;
        return step;
    }

    private static AdjustmentView buildAdjustment(
        String key,
        String category,
        String name,
        String description,
        Decimal amount,
        String direction,
        String source,
        Boolean overridden
    ) {
        AdjustmentView adjustment = new AdjustmentView();
        adjustment.key = key;
        adjustment.category = category;
        adjustment.name = name;
        adjustment.description = description;
        adjustment.amount = amount;
        adjustment.direction = direction;
        adjustment.source = source;
        adjustment.overridden = overridden;
        return adjustment;
    }

    private static TierView buildTier(
        String key,
        String tierName,
        String rangeLabel,
        Decimal rate,
        Decimal appliedQuantity,
        Decimal appliedValue
    ) {
        TierView tier = new TierView();
        tier.key = key;
        tier.tierName = tierName;
        tier.rangeLabel = rangeLabel;
        tier.rate = rate;
        tier.appliedQuantity = appliedQuantity;
        tier.appliedValue = appliedValue;
        return tier;
    }

    private static ProcedureNodeView buildProcedureNode(
        String key,
        String label,
        String detail,
        String outcome,
        Integer depth,
        Boolean matched
    ) {
        ProcedureNodeView node = new ProcedureNodeView();
        node.key = key;
        node.label = label;
        node.detail = detail;
        node.outcome = outcome;
        node.depth = depth;
        node.matched = matched;
        return node;
    }

    private static MetricView buildMetric(String key, String label, String value, String status) {
        MetricView metric = new MetricView();
        metric.key = key;
        metric.label = label;
        metric.value = value;
        metric.status = status;
        return metric;
    }

    private static RiskFlagView buildRisk(String severity, String title, String detail) {
        RiskFlagView risk = new RiskFlagView();
        risk.key = title.replace(' ', '-').toLowerCase();
        risk.severity = severity;
        risk.title = title;
        risk.detail = detail;
        return risk;
    }

    private static SourceStatusView buildSource(String objectApiName, Boolean available, Integer recordCount, String note) {
        SourceStatusView source = new SourceStatusView();
        source.logicalName = objectApiName;
        source.objectApiName = objectApiName;
        source.available = available;
        source.recordCount = recordCount;
        source.note = note;
        return source;
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal)value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf(String.valueOf(value));
        }
        if (value instanceof Long) {
            return Decimal.valueOf(String.valueOf(value));
        }
        if (value instanceof Double) {
            return Decimal.valueOf(String.valueOf(value));
        }
        if (value instanceof String) {
            try {
                return Decimal.valueOf((String)value);
            } catch (Exception ignoredException) {
                return null;
            }
        }
        return null;
    }

    private static Boolean toBoolean(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean)value;
        }
        if (value instanceof String) {
            return ((String)value).toLowerCase() == 'true';
        }
        return false;
    }

    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Decimal defaultDecimal(Decimal value) {
        return value == null ? 0 : value;
    }

    private static String defaultString(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static String formatDate(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Datetime) {
            return ((Datetime)value).format('yyyy-MM-dd HH:mm');
        }
        return String.valueOf(value);
    }

    private static String formatCurrency(Decimal value) {
        if (value == null) {
            return '$0.00';
        }
        Decimal rounded = value.setScale(2);
        return '$' + String.valueOf(rounded);
    }

    private static String formatCurrencyless(Decimal value) {
        if (value == null) {
            return '0';
        }
        Decimal normalized = value.setScale(value.scale() > 0 ? 2 : 0);
        return String.valueOf(normalized);
    }

    public class PricingTraceResponse {
        @AuraEnabled public String mode;
        @AuraEnabled public String modeLabel;
        @AuraEnabled public String headline;
        @AuraEnabled public String summary;
        @AuraEnabled public String supportMessage;
        @AuraEnabled public String contextObjectApiName;
        @AuraEnabled public String contextRecordId;
        @AuraEnabled public Decimal basePrice;
        @AuraEnabled public Decimal oldPrice;
        @AuraEnabled public Decimal finalPrice;
        @AuraEnabled public Decimal deltaAmount;
        @AuraEnabled public Boolean canReplay;
        @AuraEnabled public Boolean canUseDemo;
        @AuraEnabled public List<PricingStepView> timeline;
        @AuraEnabled public List<AdjustmentView> adjustments;
        @AuraEnabled public List<TierView> tiers;
        @AuraEnabled public List<ProcedureNodeView> procedureNodes;
        @AuraEnabled public List<MetricView> metrics;
        @AuraEnabled public List<RiskFlagView> riskFlags;
        @AuraEnabled public List<SourceStatusView> sources;
    }

    public class ReplayResponse {
        @AuraEnabled public String mode;
        @AuraEnabled public String modeLabel;
        @AuraEnabled public Decimal projectedPrice;
        @AuraEnabled public Decimal deltaAmount;
        @AuraEnabled public String message;
        @AuraEnabled public List<PricingStepView> impacts;
        @AuraEnabled public List<RiskFlagView> notices;
    }

    public class PricingStepView {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String detail;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal runningTotal;
        @AuraEnabled public String direction;
        @AuraEnabled public String source;
        @AuraEnabled public String timestampLabel;
    }

    public class AdjustmentView {
        @AuraEnabled public String key;
        @AuraEnabled public String category;
        @AuraEnabled public String name;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String direction;
        @AuraEnabled public String source;
        @AuraEnabled public Boolean overridden;
    }

    public class TierView implements Comparable {
        @AuraEnabled public String key;
        @AuraEnabled public String tierName;
        @AuraEnabled public String rangeLabel;
        @AuraEnabled public Decimal rate;
        @AuraEnabled public Decimal appliedQuantity;
        @AuraEnabled public Decimal appliedValue;

        public Integer compareTo(Object otherObject) {
            TierView otherTier = (TierView)otherObject;
            Decimal currentStart = extractRangeStart(rangeLabel);
            Decimal otherStart = extractRangeStart(otherTier.rangeLabel);
            if (currentStart == null && otherStart == null) {
                return 0;
            }
            if (currentStart == null) {
                return -1;
            }
            if (otherStart == null) {
                return 1;
            }
            if (currentStart == otherStart) {
                return 0;
            }
            return currentStart < otherStart ? -1 : 1;
        }
    }

    public class ProcedureNodeView {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String detail;
        @AuraEnabled public String outcome;
        @AuraEnabled public Integer depth;
        @AuraEnabled public Boolean matched;
    }

    public class MetricView {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String status;
    }

    public class RiskFlagView {
        @AuraEnabled public String key;
        @AuraEnabled public String severity;
        @AuraEnabled public String title;
        @AuraEnabled public String detail;
    }

    public class SourceStatusView {
        @AuraEnabled public String logicalName;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public Boolean available;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public String note;
    }

    private class LiveTraceContext {
        public Map<String, ResolvedObjectConfig> resolvedByKey = new Map<String, ResolvedObjectConfig>();
        public Map<String, List<SObject>> recordsByKey = new Map<String, List<SObject>>();
        public List<SourceStatusView> sources = new List<SourceStatusView>();
        public Set<String> anchorIds = new Set<String>();

        public Boolean hasSourceRecords() {
            for (List<SObject> records : recordsByKey.values()) {
                if (records != null && !records.isEmpty()) {
                    return true;
                }
            }
            return false;
        }
    }

    private class TraceObjectConfig {
        public String key;
        public String label;
        public List<String> objectCandidates;
        public List<String> relationFields;
        public List<String> anchorFields;
        public Map<String, List<String>> semanticCandidates;

        public TraceObjectConfig(
            String key,
            String label,
            List<String> objectCandidates,
            List<String> relationFields,
            List<String> anchorFields,
            Map<String, List<String>> semanticCandidates
        ) {
            this.key = key;
            this.label = label;
            this.objectCandidates = objectCandidates;
            this.relationFields = relationFields;
            this.anchorFields = anchorFields;
            this.semanticCandidates = semanticCandidates;
        }
    }

    private class ResolvedObjectConfig {
        public String key;
        public String label;
        public String objectApiName;
        public List<String> selectFields = new List<String>();
        public List<String> relationFields = new List<String>();
        public List<String> anchorFields = new List<String>();
        public Map<String, String> fieldBySemantic = new Map<String, String>();
        public String orderField;
    }
}

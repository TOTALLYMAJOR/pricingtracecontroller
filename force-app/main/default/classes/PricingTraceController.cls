public with sharing class PricingTraceController {
    @AuraEnabled(cacheable=true)
    public static PricingTraceService.PricingTraceResponse getTrace(
        String recordId,
        String contextObjectApiName,
        Boolean forceDemoMode
    ) {
        return PricingTraceService.getTrace(recordId, contextObjectApiName, forceDemoMode);
    }

    @AuraEnabled
    public static PricingTraceService.ReplayResponse simulateReplay(
        String recordId,
        String contextObjectApiName,
        Decimal quantity,
        Boolean premiumSupport,
        String regionCode,
        Boolean forceDemoMode
    ) {
        return PricingTraceService.simulateReplay(
            recordId,
            contextObjectApiName,
            quantity,
            premiumSupport,
            regionCode,
            forceDemoMode
        );
    }
}

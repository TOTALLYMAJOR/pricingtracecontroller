@IsTest
private class PricingTraceServiceTest {
    @IsTest
    static void returnsDemoTraceWhenForced() {
        Test.startTest();
        PricingTraceService.PricingTraceResponse response = PricingTraceService.getTrace(
            null,
            'QuoteLine',
            true
        );
        Test.stopTest();

        System.assertEquals('demo', response.mode);
        System.assertEquals(5, response.timeline.size());
        System.assertEquals(2950, response.finalPrice);
        System.assertEquals(true, response.canReplay);
    }

    @IsTest
    static void returnsEmptyTraceWhenNoLiveSourcesExist() {
        Test.startTest();
        PricingTraceService.PricingTraceResponse response = PricingTraceService.getTrace(
            'a010000000000001AAA',
            'QuoteLine',
            false
        );
        Test.stopTest();

        System.assertEquals('empty', response.mode);
        System.assertEquals(true, response.canUseDemo);
        System.assertEquals(0, response.timeline.size());
        System.assert(!response.riskFlags.isEmpty(), 'Expected empty-state risks to be returned.');
    }

    @IsTest
    static void buildsReplayProjection() {
        Test.startTest();
        PricingTraceService.ReplayResponse response = PricingTraceService.simulateReplay(
            null,
            'QuoteLine',
            180,
            true,
            'EMEA',
            true
        );
        Test.stopTest();

        System.assertEquals('simulation', response.mode);
        System.assertEquals(3975, response.projectedPrice);
        System.assertEquals(1475, response.deltaAmount);
        System.assertEquals(4, response.impacts.size());
    }
}

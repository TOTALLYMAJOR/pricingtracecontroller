import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getTrace from '@salesforce/apex/PricingTraceController.getTrace';
import simulateReplay from '@salesforce/apex/PricingTraceController.simulateReplay';

const currencyFormatter = new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 2
});

const numberFormatter = new Intl.NumberFormat('en-US', {
    maximumFractionDigits: 2
});

const regionOptions = [
    { label: 'North America', value: 'NA' },
    { label: 'EMEA', value: 'EMEA' },
    { label: 'APAC', value: 'APAC' }
];

export default class PricingTraceExplorer extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api demoMode = false;

    useDemoMode = false;
    trace;
    errorMessage;
    wiredTraceResult;

    isReplayOpen = false;
    isReplaying = false;
    replayResponse;
    replayQuantity = 120;
    replayRegionCode = 'NA';
    replayPremiumSupport = true;

    connectedCallback() {
        this.useDemoMode = Boolean(this.demoMode);
    }

    @wire(getTrace, {
        recordId: '$recordId',
        contextObjectApiName: '$resolvedObjectApiName',
        forceDemoMode: '$effectiveDemoMode'
    })
    wiredTrace(value) {
        this.wiredTraceResult = value;
        const { data, error } = value;

        if (data) {
            this.trace = decorateTrace(data);
            this.errorMessage = undefined;
            return;
        }

        if (error) {
            this.trace = undefined;
            this.errorMessage = reduceErrors(error);
        }
    }

    get resolvedObjectApiName() {
        return this.objectApiName || 'QuoteLine';
    }

    get effectiveDemoMode() {
        return this.useDemoMode || !this.recordId;
    }

    get isLoading() {
        return !this.trace && !this.errorMessage;
    }

    get hasTrace() {
        return Boolean(this.trace);
    }

    get hasError() {
        return Boolean(this.errorMessage);
    }

    get modeLabel() {
        return this.trace?.modeLabel || 'Pricing Trace';
    }

    get summary() {
        if (this.trace?.summary) {
            return this.trace.summary;
        }

        return 'Surface opaque pricing behavior with a recruiter-friendly operational trace.';
    }

    get supportMessage() {
        return this.trace?.supportMessage;
    }

    get modeBadgeClass() {
        const mode = this.trace?.mode || 'loading';
        return `chip chip_mode chip_mode-${mode}`;
    }

    get contextLabel() {
        return this.recordId ? `${this.resolvedObjectApiName} record` : `${this.resolvedObjectApiName} preview`;
    }

    get metricCards() {
        return this.trace?.metrics || [];
    }

    get oldPriceLabel() {
        return formatCurrency(this.trace?.oldPrice);
    }

    get finalPriceLabel() {
        return formatCurrency(this.trace?.finalPrice);
    }

    get deltaLabel() {
        return formatSignedCurrency(this.trace?.deltaAmount, false);
    }

    get timelineItems() {
        return this.trace?.timeline || [];
    }

    get hasTimeline() {
        return this.timelineItems.length > 0;
    }

    get adjustmentCards() {
        return this.trace?.adjustments || [];
    }

    get hasAdjustments() {
        return this.adjustmentCards.length > 0;
    }

    get tierRows() {
        return this.trace?.tiers || [];
    }

    get hasTiers() {
        return this.tierRows.length > 0;
    }

    get procedureRows() {
        return this.trace?.procedureNodes || [];
    }

    get hasProcedureNodes() {
        return this.procedureRows.length > 0;
    }

    get riskCards() {
        return this.trace?.riskFlags || [];
    }

    get hasRiskFlags() {
        return this.riskCards.length > 0;
    }

    get sourceCards() {
        return this.trace?.sources || [];
    }

    get topCauses() {
        return this.adjustmentCards.slice(0, 3);
    }

    get hasTopCauses() {
        return this.topCauses.length > 0;
    }

    get disableReplay() {
        return !this.trace?.canReplay;
    }

    get canReplay() {
        return Boolean(this.trace?.canReplay);
    }

    get regionOptions() {
        return regionOptions;
    }

    get hasReplayResponse() {
        return Boolean(this.replayResponse);
    }

    get replayProjectedPriceLabel() {
        return formatCurrency(this.replayResponse?.projectedPrice);
    }

    get replayDeltaLabel() {
        return formatSignedCurrency(this.replayResponse?.deltaAmount, false);
    }

    get replayMessage() {
        return this.replayResponse?.message;
    }

    get replayImpactItems() {
        return this.replayResponse?.impacts || [];
    }

    get replayNoticeCards() {
        return this.replayResponse?.notices || [];
    }

    get hasReplayNotices() {
        return this.replayNoticeCards.length > 0;
    }

    async handleRefresh() {
        this.replayResponse = undefined;
        if (this.wiredTraceResult) {
            await refreshApex(this.wiredTraceResult);
        }
    }

    handleDemoToggle(event) {
        this.useDemoMode = event.target.checked;
        this.replayResponse = undefined;
    }

    handleEnableDemo() {
        this.useDemoMode = true;
    }

    handleOpenReplay() {
        this.isReplayOpen = true;
    }

    handleCloseReplay() {
        this.isReplayOpen = false;
    }

    handleReplayInput(event) {
        const field = event.target.dataset.field;

        if (field === 'quantity') {
            this.replayQuantity = event.target.value;
        } else if (field === 'regionCode') {
            this.replayRegionCode = event.detail.value;
        } else if (field === 'premiumSupport') {
            this.replayPremiumSupport = event.target.checked;
        }
    }

    async handleRunReplay() {
        this.isReplaying = true;

        try {
            const response = await simulateReplay({
                recordId: this.recordId,
                contextObjectApiName: this.resolvedObjectApiName,
                quantity: normalizeNumber(this.replayQuantity),
                premiumSupport: this.replayPremiumSupport,
                regionCode: this.replayRegionCode,
                forceDemoMode: this.effectiveDemoMode
            });

            this.replayResponse = decorateReplay(response);
        } catch (error) {
            this.replayResponse = {
                projectedPrice: undefined,
                deltaAmount: undefined,
                message: reduceErrors(error),
                impacts: [],
                notices: [
                    decorateRisk({
                        key: 'replay-error',
                        severity: 'danger',
                        title: 'Replay Failed',
                        detail: reduceErrors(error)
                    })
                ]
            };
        } finally {
            this.isReplaying = false;
        }
    }
}

function decorateTrace(trace) {
    const decorated = { ...trace };

    decorated.timeline = (trace.timeline || []).map((item) => decorateTimelineItem(item));
    decorated.adjustments = sortAdjustmentsByMagnitude(trace.adjustments || []).map((item) => decorateAdjustment(item));
    decorated.tiers = (trace.tiers || []).map((item) => ({
        ...item,
        rateDisplay: formatCurrency(item.rate),
        quantityDisplay: formatNumber(item.appliedQuantity),
        valueDisplay: formatCurrency(item.appliedValue)
    }));
    decorated.procedureNodes = (trace.procedureNodes || []).map((item) => ({
        ...item,
        className: `procedure procedure_${item.matched ? 'matched' : 'unmatched'}`,
        indentStyle: `--depth:${item.depth || 0};`,
        outcomeClass: `chip ${item.matched ? 'chip_success' : 'chip_warning'}`
    }));
    decorated.metrics = (trace.metrics || []).map((item) => ({
        ...item,
        className: `metric metric_${item.status || 'ok'}`
    }));
    decorated.riskFlags = (trace.riskFlags || []).map((item) => decorateRisk(item));
    decorated.sources = (trace.sources || []).map((item) => ({
        ...item,
        className: `source source_${item.available ? 'live' : 'offline'}`,
        countLabel: `${item.recordCount || 0} rows`
    }));

    return decorated;
}

function decorateReplay(response) {
    return {
        ...response,
        impacts: (response.impacts || []).map((item) => decorateTimelineItem(item)),
        notices: (response.notices || []).map((item) => decorateRisk(item))
    };
}

function decorateTimelineItem(item) {
    const direction = item.direction || 'neutral';
    return {
        ...item,
        className: `timeline-card timeline-card_${direction}`,
        markerClass: `timeline-marker timeline-marker_${direction}`,
        amountDisplay: formatSignedCurrency(item.amount, direction === 'neutral'),
        runningTotalDisplay: formatCurrency(item.runningTotal)
    };
}

function decorateAdjustment(item) {
    const direction = item.direction || 'neutral';
    return {
        ...item,
        className: `adjustment adjustment_${direction}`,
        directionClass: `pill pill_${direction}`,
        amountDisplay: formatSignedCurrency(item.amount, false)
    };
}

function decorateRisk(item) {
    const severity = item.severity || 'info';
    return {
        ...item,
        className: `risk risk_${severity}`,
        badgeClass: `chip ${severity === 'danger' ? 'chip_danger' : severity === 'warning' ? 'chip_warning' : 'chip_info'}`,
        severityLabel: severity.toUpperCase()
    };
}

function sortAdjustmentsByMagnitude(items) {
    return [...items].sort((left, right) => {
        const leftMagnitude = Math.abs(normalizeNumber(left.amount));
        const rightMagnitude = Math.abs(normalizeNumber(right.amount));
        return rightMagnitude - leftMagnitude;
    });
}

function formatCurrency(value) {
    if (!hasPresentValue(value)) {
        return '--';
    }
    return currencyFormatter.format(normalizeNumber(value));
}

function formatSignedCurrency(value, neutral = false) {
    if (!hasPresentValue(value)) {
        return '--';
    }

    const amount = normalizeNumber(value);
    if (neutral || amount === 0) {
        return currencyFormatter.format(amount);
    }

    return `${amount > 0 ? '+' : '-'}${currencyFormatter.format(Math.abs(amount))}`;
}

function formatNumber(value) {
    if (!hasPresentValue(value)) {
        return '--';
    }
    return numberFormatter.format(normalizeNumber(value));
}

function normalizeNumber(value) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
}

function hasPresentValue(value) {
    return value !== undefined && value !== null && value !== '';
}

function reduceErrors(error) {
    if (!error) {
        return 'Unknown error';
    }

    if (Array.isArray(error.body)) {
        return error.body.map((item) => item.message).join(', ');
    }

    if (error.body && typeof error.body.message === 'string') {
        return error.body.message;
    }

    if (typeof error.message === 'string') {
        return error.message;
    }

    return 'Unknown error';
}

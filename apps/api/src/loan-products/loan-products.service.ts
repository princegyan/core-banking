import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';

import { SupabaseService } from '../database/supabase.service';

import { CreateLoanProductDto } from './dto/create-loan-product.dto';
import { UpdateLoanProductDto } from './dto/update-loan-product.dto';
import { AddGlMappingDto } from './dto/add-gl-mapping.dto';
import { AddProductChargeDto } from './dto/add-product-charge.dto';

@Injectable()
export class LoanProductsService {
  constructor(
    private readonly supabaseService: SupabaseService,
  ) {}

  async create(
    tenantId: string,
    userId: string,
    dto: CreateLoanProductDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'create_loan_product',
        {
          p_tenant_id: tenantId,
          p_code: dto.code,
          p_name: dto.name,
          p_description: dto.description ?? null,
          p_product_type: dto.productType,
          p_currency: dto.currency,
          p_minimum_principal: dto.minimumPrincipal,
          p_maximum_principal: dto.maximumPrincipal,
          p_annual_interest_rate: dto.annualInterestRate,
          p_interest_method: dto.interestMethod,
          p_interest_calculation_basis:
            dto.interestCalculationBasis,
          p_minimum_term_days: dto.minimumTermDays,
          p_maximum_term_days: dto.maximumTermDays,
          p_repayment_frequency:
            dto.repaymentFrequency,
          p_amortization_type:
            dto.amortizationType,
          p_grace_period_days:
            dto.gracePeriodDays ?? 0,
          p_grace_period_interest:
            dto.gracePeriodInterest ?? true,
          p_penalty_rate:
            dto.penaltyRate ?? 0,
          p_penalty_grace_days:
            dto.penaltyGraceDays ?? 0,
          p_requires_collateral:
            dto.requiresCollateral ?? false,
          p_minimum_collateral_ratio:
            dto.minimumCollateralRatio ?? null,
          p_requires_guarantor:
            dto.requiresGuarantor ?? false,
          p_minimum_guarantors:
            dto.minimumGuarantors ?? 0,
          p_allow_prepayment:
            dto.allowPrepayment ?? true,
          p_prepayment_penalty_rate:
            dto.prepaymentPenaltyRate ?? 0,
          p_default_principal:
            dto.defaultPrincipal ?? null,
          p_default_term_days:
            dto.defaultTermDays ?? null,
          p_balloon_percentage:
            dto.balloonPercentage ?? null,
          p_created_by: userId,
        },
      );

    if (error) {
      console.error(
        'Loan product creation failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async findAll(tenantId: string) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('loan_products')
        .select(`
          id,
          code,
          name,
          description,
          product_type,
          currency,
          minimum_principal,
          maximum_principal,
          annual_interest_rate,
          interest_method,
          interest_calculation_basis,
          minimum_term_days,
          maximum_term_days,
          repayment_frequency,
          amortization_type,
          grace_period_days,
          penalty_rate,
          requires_collateral,
          requires_guarantor,
          allow_prepayment,
          is_active,
          created_at,
          updated_at
        `)
        .eq('tenant_id', tenantId)
        .order('created_at', {
          ascending: false,
        });

    if (error) {
      console.error(
        'Loan products lookup failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async findOne(
    tenantId: string,
    productId: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('loan_products')
        .select(`
          id,
          code,
          name,
          description,
          product_type,
          currency,
          minimum_principal,
          maximum_principal,
          default_principal,
          annual_interest_rate,
          interest_method,
          interest_calculation_basis,
          minimum_term_days,
          maximum_term_days,
          default_term_days,
          repayment_frequency,
          amortization_type,
          balloon_percentage,
          grace_period_days,
          grace_period_interest,
          penalty_rate,
          penalty_grace_days,
          arrears_days_threshold_1,
          arrears_days_threshold_2,
          arrears_days_threshold_3,
          requires_collateral,
          minimum_collateral_ratio,
          requires_guarantor,
          minimum_guarantors,
          allow_prepayment,
          prepayment_penalty_rate,
          is_active,
          created_by,
          created_at,
          updated_at,
          loan_product_gl_mappings (
            id,
            mapping_type,
            ledger_account_id,
            is_active
          ),
          loan_product_charges (
            id,
            fee_id,
            charge_event,
            is_mandatory,
            is_active,
            fees (
              code,
              name,
              calculation_type,
              amount,
              currency
            )
          )
        `)
        .eq('id', productId)
        .eq('tenant_id', tenantId)
        .maybeSingle();

    if (error) {
      throw new BadRequestException(
        error.message,
      );
    }

    if (!data) {
      throw new NotFoundException(
        'Loan product not found',
      );
    }

    return data;
  }

  async update(
    tenantId: string,
    productId: string,
    dto: UpdateLoanProductDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'update_loan_product',
        {
          p_tenant_id: tenantId,
          p_product_id: productId,
          p_name: dto.name ?? null,
          p_description: dto.description ?? null,
          p_minimum_principal:
            dto.minimumPrincipal ?? null,
          p_maximum_principal:
            dto.maximumPrincipal ?? null,
          p_annual_interest_rate:
            dto.annualInterestRate ?? null,
          p_minimum_term_days:
            dto.minimumTermDays ?? null,
          p_maximum_term_days:
            dto.maximumTermDays ?? null,
          p_grace_period_days:
            dto.gracePeriodDays ?? null,
          p_grace_period_interest:
            dto.gracePeriodInterest ?? null,
          p_penalty_rate:
            dto.penaltyRate ?? null,
          p_penalty_grace_days:
            dto.penaltyGraceDays ?? null,
          p_requires_collateral:
            dto.requiresCollateral ?? null,
          p_minimum_collateral_ratio:
            dto.minimumCollateralRatio ?? null,
          p_requires_guarantor:
            dto.requiresGuarantor ?? null,
          p_minimum_guarantors:
            dto.minimumGuarantors ?? null,
          p_allow_prepayment:
            dto.allowPrepayment ?? null,
          p_prepayment_penalty_rate:
            dto.prepaymentPenaltyRate ?? null,
          p_is_active:
            dto.isActive ?? null,
        },
      );

    if (error) {
      console.error(
        'Loan product update failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async addGlMapping(
    tenantId: string,
    productId: string,
    dto: AddGlMappingDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'add_loan_product_gl_mapping',
        {
          p_tenant_id: tenantId,
          p_loan_product_id: productId,
          p_mapping_type: dto.mappingType,
          p_ledger_account_id:
            dto.ledgerAccountId,
        },
      );

    if (error) {
      console.error(
        'GL mapping failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async getGlMappings(
    tenantId: string,
    productId: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('loan_product_gl_mappings')
        .select(`
          id,
          mapping_type,
          ledger_account_id,
          is_active,
          created_at,
          ledger_accounts (
            account_code,
            account_name,
            account_type
          )
        `)
        .eq('tenant_id', tenantId)
        .eq('loan_product_id', productId)
        .eq('is_active', true)
        .order('mapping_type');

    if (error) {
      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async addCharge(
    tenantId: string,
    productId: string,
    dto: AddProductChargeDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'add_loan_product_charge',
        {
          p_tenant_id: tenantId,
          p_loan_product_id: productId,
          p_fee_id: dto.feeId,
          p_charge_event: dto.chargeEvent,
          p_is_mandatory:
            dto.isMandatory ?? true,
        },
      );

    if (error) {
      console.error(
        'Loan product charge failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async getCharges(
    tenantId: string,
    productId: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('loan_product_charges')
        .select(`
          id,
          charge_event,
          is_mandatory,
          is_active,
          created_at,
          fees (
            id,
            code,
            name,
            calculation_type,
            amount,
            minimum_amount,
            maximum_amount,
            currency
          )
        `)
        .eq('tenant_id', tenantId)
        .eq('loan_product_id', productId)
        .eq('is_active', true)
        .order('charge_event');

    if (error) {
      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }
}

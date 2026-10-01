import { Injectable, BadRequestException } from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';

@Injectable()
export class ReportingService {
  constructor(private readonly supabaseService: SupabaseService) {}

  async generateAccountStatement(tenantId: string, accountId: string, fromDate?: string, toDate?: string) {
    const supabase = this.supabaseService.getClient();
    
    // Default dates if not provided
    const fd = fromDate || new Date(0).toISOString().split('T')[0];
    const td = toDate || new Date().toISOString().split('T')[0];

    const { data, error } = await supabase.rpc('generate_account_statement', {
      p_tenant_id: tenantId,
      p_account_id: accountId,
      p_from_date: fd,
      p_to_date: td,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async generateTrialBalance(tenantId: string, asOfDate?: string) {
    const supabase = this.supabaseService.getClient();
    
    const ad = asOfDate || new Date().toISOString().split('T')[0];

    const { data, error } = await supabase.rpc('generate_trial_balance', {
      p_tenant_id: tenantId,
      p_as_of_date: ad,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async generateGlReport(tenantId: string, accountCode: string, fromDate?: string, toDate?: string) {
    const supabase = this.supabaseService.getClient();

    const fd = fromDate || new Date(0).toISOString().split('T')[0];
    const td = toDate || new Date().toISOString().split('T')[0];

    const { data, error } = await supabase.rpc('generate_gl_report', {
      p_tenant_id: tenantId,
      p_account_code: accountCode,
      p_from_date: fd,
      p_to_date: td,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async generateCashPosition(tenantId: string, branchId?: string) {
    const supabase = this.supabaseService.getClient();

    const { data, error } = await supabase.rpc('generate_cash_position', {
      p_tenant_id: tenantId,
      p_branch_id: branchId || null,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async generateDailyTransactionReport(tenantId: string, businessDate?: string) {
    const supabase = this.supabaseService.getClient();
    
    const bd = businessDate || new Date().toISOString().split('T')[0];

    const { data, error } = await supabase.rpc('generate_daily_transaction_report', {
      p_tenant_id: tenantId,
      p_business_date: bd,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async generateIncomeReport(tenantId: string, fromDate?: string, toDate?: string) {
    const supabase = this.supabaseService.getClient();

    const fd = fromDate || new Date(0).toISOString().split('T')[0];
    const td = toDate || new Date().toISOString().split('T')[0];

    const { data, error } = await supabase.rpc('generate_income_report', {
      p_tenant_id: tenantId,
      p_from_date: fd,
      p_to_date: td,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }
}

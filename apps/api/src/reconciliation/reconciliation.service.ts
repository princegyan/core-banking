import { Injectable, BadRequestException, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { CreateSuspenseDto, ClearSuspenseDto, ResolveExceptionDto } from './dto/run-reconciliation.dto';

@Injectable()
export class ReconciliationService {
  constructor(private readonly supabase: SupabaseService) {}

  async runGlCustomerReconciliation(tenantId: string, createdBy: string) {
    const { data, error } = await this.supabase.getClient().rpc('reconcile_gl_customer_accounts', {
      p_tenant_id: tenantId,
      p_created_by: createdBy,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async runCashPositionReconciliation(tenantId: string, branchId: string | undefined, createdBy: string) {
    if (!branchId) {
      throw new BadRequestException('branchId is required for cash reconciliation');
    }
    const { data, error } = await this.supabase.getClient().rpc('reconcile_cash_position', {
      p_tenant_id: tenantId,
      p_branch_id: branchId,
      p_created_by: createdBy,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async runLedgerBalanceReconciliation(tenantId: string, createdBy: string) {
    const { data, error } = await this.supabase.getClient().rpc('detect_ledger_imbalances', {
      p_tenant_id: tenantId,
      p_created_by: createdBy,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getRuns(tenantId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('reconciliation_runs')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async getRunById(tenantId: string, id: string) {
    const { data, error } = await this.supabase.getClient()
      .from('reconciliation_runs')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('id', id)
      .single();

    if (error) {
      throw new NotFoundException('Reconciliation run not found');
    }

    return data;
  }

  async getExceptions(tenantId: string) {
    const { data, error } = await this.supabase.getClient()
      .from('reconciliation_exceptions')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async resolveException(tenantId: string, exceptionId: string, resolvedBy: string, dto: ResolveExceptionDto) {
    const { data, error } = await this.supabase.getClient()
      .from('reconciliation_exceptions')
      .update({
        resolution_status: 'RESOLVED',
        resolved_by: resolvedBy,
        resolved_at: new Date().toISOString(),
        resolution_notes: dto.resolutionNotes,
      })
      .eq('id', exceptionId)
      .eq('tenant_id', tenantId)
      .select()
      .single();

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async createSuspenseEntry(tenantId: string, dto: CreateSuspenseDto) {
    const { data, error } = await this.supabase.getClient().rpc('create_suspense_entry', {
      p_tenant_id: tenantId,
      p_amount: dto.amount,
      p_currency: dto.currency,
      p_reason: dto.reason,
      p_original_transaction_id: dto.originalTransactionId || null,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }

  async clearSuspenseEntry(tenantId: string, suspenseId: string, clearedBy: string, dto: ClearSuspenseDto) {
    const { data, error } = await this.supabase.getClient().rpc('clear_suspense_entry', {
      p_tenant_id: tenantId,
      p_suspense_id: suspenseId,
      p_cleared_by: clearedBy,
      p_notes: dto.notes,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }

    return data;
  }
}

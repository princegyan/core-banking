import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';

@Injectable()
export class EodService {
  constructor(private readonly supabaseService: SupabaseService) {}

  async validateReadiness(tenantId: string, businessDateId: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase.rpc('validate_eod_readiness', {
      p_tenant_id: tenantId,
      p_business_date_id: businessDateId,
    });
    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async startEodProcessing(tenantId: string, businessDateId: string, initiatedBy: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase.rpc('start_eod_processing', {
      p_tenant_id: tenantId,
      p_business_date_id: businessDateId,
      p_initiated_by: initiatedBy,
    });
    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async executeStep(tenantId: string, batchId: string, stepType: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase.rpc('execute_eod_step', {
      p_tenant_id: tenantId,
      p_batch_id: batchId,
      p_step_type: stepType,
    });
    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async completeEodProcessing(tenantId: string, batchId: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase.rpc('complete_eod_processing', {
      p_tenant_id: tenantId,
      p_batch_id: batchId,
    });
    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async advanceBusinessDate(tenantId: string, currentBusinessDateId: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase.rpc('advance_business_date', {
      p_tenant_id: tenantId,
      p_current_business_date_id: currentBusinessDateId,
    });
    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async getBatches(tenantId: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase
      .from('eod_batches')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });
    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async getBatchDetails(tenantId: string, batchId: string) {
    const supabase = this.supabaseService.getClient();
    const { data, error } = await supabase
      .from('eod_batches')
      .select(`
        *,
        eod_batch_steps (*)
      `)
      .eq('id', batchId)
      .eq('tenant_id', tenantId)
      .maybeSingle();

    if (error) {
      throw new BadRequestException(error.message);
    }
    if (!data) {
      throw new NotFoundException('Batch not found');
    }
    return data;
  }
}

import { Injectable, BadRequestException } from '@nestjs/common';
import { SupabaseService } from '../database/supabase.service';
import { RunAccrualDto } from './dto/run-accrual.dto';
import { PostInterestDto } from './dto/post-interest.dto';

@Injectable()
export class InterestService {
  constructor(private readonly supabaseService: SupabaseService) {}

  async runAccrual(tenantId: string, dto: RunAccrualDto) {
    const { data, error } = await this.supabaseService.getClient().rpc('accrue_interest_for_date', {
      p_tenant_id: tenantId,
      p_accrual_date: dto.accrualDate,
      p_account_type: dto.accountType,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async postInterest(tenantId: string, userId: string, dto: PostInterestDto) {
    const { data, error } = await this.supabaseService.getClient().rpc('post_accrued_interest', {
      p_tenant_id: tenantId,
      p_posting_date: dto.postingDate,
      p_account_type: dto.accountType,
      p_created_by: userId,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async getAccountAccruals(tenantId: string, accountId: string, fromDate: string, toDate: string) {
    const { data, error } = await this.supabaseService.getClient().rpc('get_account_accrued_interest', {
      p_tenant_id: tenantId,
      p_account_id: accountId,
      p_from_date: fromDate,
      p_to_date: toDate,
    });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }

  async getBatches(tenantId: string) {
    const { data, error } = await this.supabaseService.getClient()
      .from('interest_posting_batches')
      .select('*')
      .eq('tenant_id', tenantId)
      .order('created_at', { ascending: false });

    if (error) {
      throw new BadRequestException(error.message);
    }
    return data;
  }
}

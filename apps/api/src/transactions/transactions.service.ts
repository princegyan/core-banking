import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';

import { SupabaseService } from '../database/supabase.service';

import { CreateDepositDto } from './dto/create-deposit.dto';
import { CreateWithdrawalDto } from './dto/create-withdrawal.dto';

@Injectable()
export class TransactionsService {
  constructor(
    private readonly supabaseService: SupabaseService,
  ) {}

  async createDeposit(
    tenantId: string,
    userId: string,
    dto: CreateDepositDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'post_deposit',
        {
          p_tenant_id: tenantId,
          p_account_id: dto.accountId,
          p_amount: dto.amount,
          p_description: dto.description,
          p_idempotency_key:
            dto.idempotencyKey ?? null,
          p_created_by: userId,
        },
      );

    if (error) {
      const message =
        error.message || 'Deposit failed';

      if (
        message
          .toLowerCase()
          .includes('account not found')
      ) {
        throw new NotFoundException(message);
      }

      throw new BadRequestException(message);
    }

    return data;
  }

  async createWithdrawal(
    tenantId: string,
    userId: string,
    dto: CreateWithdrawalDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'post_withdrawal',
        {
          p_tenant_id: tenantId,
          p_account_id: dto.accountId,
          p_amount: dto.amount,
          p_description: dto.description,
          p_idempotency_key:
            dto.idempotencyKey ?? null,
          p_created_by: userId,
        },
      );

    if (error) {
      const message =
        error.message || 'Withdrawal failed';

      if (
        message
          .toLowerCase()
          .includes('account not found')
      ) {
        throw new NotFoundException(message);
      }

      throw new BadRequestException(message);
    }

    return data;
  }
}
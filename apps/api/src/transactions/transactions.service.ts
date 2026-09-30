import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';

import { SupabaseService } from '../database/supabase.service';

import { CreateDepositDto } from './dto/create-deposit.dto';
import { CreateWithdrawalDto } from './dto/create-withdrawal.dto';
import { CreateTransferDto } from './dto/create-transfer.dto';
import { CreateReversalDto } from './dto/create-reversal.dto';

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

  async postTransfer(
    tenantId: string,
    userId: string,
    dto: CreateTransferDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'post_internal_transfer',
        {
          p_tenant_id: tenantId,
          p_source_account_id:
            dto.sourceAccountId,
          p_destination_account_id:
            dto.destinationAccountId,
          p_amount: dto.amount,
          p_description:
            dto.description,
          p_idempotency_key:
            dto.idempotencyKey ?? null,
          p_created_by: userId,
        },
      );

    if (error) {
      const message =
        error.message || 'Transfer failed';

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
async createReversal(
  tenantId: string,
  userId: string,
  dto: CreateReversalDto,
) {
  const supabase =
    this.supabaseService.getClient();

  const { data, error } =
    await supabase.rpc(
      'execute_authorized_transaction_reversal',
      {
        p_tenant_id: tenantId,
        p_transaction_id: dto.transactionId,
        p_requested_by: userId,
        p_comment: dto.reason,
      },
    );

  if (error) {
    const message =
      error.message || 'Transaction reversal failed';

    throw new BadRequestException(message);
  }

  return data;
}
  async listTransactions(
    tenantId: string,
    page = 1,
    limit = 20,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const safePage = Math.max(1, page);
    const safeLimit = Math.min(
      Math.max(1, limit),
      100,
    );

    const from =
      (safePage - 1) * safeLimit;

    const to =
      from + safeLimit - 1;

    const {
      data,
      error,
      count,
    } = await supabase
      .from('transactions')
      .select(
        `
          id,
          reference,
          transaction_type,
          status,
          currency,
          amount,
          description,
          channel,
          value_date,
          posted_at,
          created_at,
          created_by
        `,
        { count: 'exact' },
      )
      .eq('tenant_id', tenantId)
      .order('created_at', {
        ascending: false,
      })
      .range(from, to);

    if (error) {
      throw new BadRequestException(
        error.message ||
          'Failed to retrieve transactions',
      );
    }

    return {
      data,
      pagination: {
        page: safePage,
        limit: safeLimit,
        total: count ?? 0,
        totalPages: Math.ceil(
          (count ?? 0) / safeLimit,
        ),
      },
    };
  }
}
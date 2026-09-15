import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';

import { SupabaseService } from '../database/supabase.service';

import { CreateAccountDto } from './dto/create-account.dto';

@Injectable()
export class AccountsService {
  constructor(
    private readonly supabaseService: SupabaseService,
  ) {}

  async createAccount(
    tenantId: string,
    dto: CreateAccountDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'open_customer_account',
        {
          p_tenant_id: tenantId,
          p_customer_id: dto.customerId,
          p_product_id: dto.productId,
          p_branch_id: dto.branchId,
          p_currency: dto.currency,
        },
      );

    if (error) {
      console.error(
        'Account creation failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }

  async findAll(
    tenantId: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('accounts')
        .select(`
          id,
          account_number,
          currency,
          status,
          ledger_balance,
          available_balance,
          opened_at,
          closed_at,
          created_at,
          updated_at,
          customer_id,
          customers (
            customer_number,
            customer_type,
            first_name,
            last_name,
            business_name
          ),
          product_id,
          account_products (
            code,
            name
          ),
          branch_id,
          branches (
            code,
            name
          )
        `)
        .eq('tenant_id', tenantId)
        .order('created_at', {
          ascending: false,
        });

    if (error) {
      console.error(
        'Account lookup failed:',
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
    accountId: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('accounts')
        .select(`
          id,
          account_number,
          currency,
          status,
          ledger_balance,
          available_balance,
          opened_at,
          closed_at,
          created_at,
          updated_at,
          customer_id,
          customers (
            customer_number,
            customer_type,
            first_name,
            last_name,
            business_name
          ),
          product_id,
          account_products (
            code,
            name,
            description,
            interest_rate,
            minimum_balance
          ),
          branch_id,
          branches (
            code,
            name
          ),
          ledger_account_id
        `)
        .eq('id', accountId)
        .eq('tenant_id', tenantId)
        .maybeSingle();

    if (error) {
      throw new BadRequestException(
        error.message,
      );
    }

    if (!data) {
      throw new NotFoundException(
        'Account not found',
      );
    }

    return data;
  }

  async updateAccountStatus(
    tenantId: string,
    accountId: string,
    status: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase.rpc(
        'update_account_status',
        {
          p_tenant_id: tenantId,
          p_account_id: accountId,
          p_new_status: status,
        },
      );

    if (error) {
      console.error(
        'Account status update failed:',
        error.message,
      );

      throw new BadRequestException(
        error.message,
      );
    }

    return data;
  }
}
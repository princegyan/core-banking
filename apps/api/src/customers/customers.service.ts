import {
  BadRequestException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';

import { SupabaseService } from '../database/supabase.service';

import { CreateCustomerDto } from './dto/create-customer.dto';
import { UpdateCustomerDto } from './dto/update-customer.dto';

@Injectable()
export class CustomersService {
  constructor(
    private readonly supabaseService: SupabaseService,
  ) {}

  async createCustomer(
    tenantId: string,
    dto: CreateCustomerDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const customerNumber =
      await this.generateCustomerNumber(
        tenantId,
      );

    const { data, error } =
      await supabase
        .from('customers')
        .insert({
          tenant_id: tenantId,
          customer_number: customerNumber,
          customer_type: dto.customerType,
          first_name: dto.firstName,
          last_name: dto.lastName,
          phone: dto.phone ?? null,
          email: dto.email ?? null,
          identification_type:
            dto.identificationType ?? null,
          identification_number:
            dto.identificationNumber ?? null,
          kyc_status: 'PENDING',
          status: 'ACTIVE',
        })
        .select()
        .single();

    if (error) {
      console.error(
        'Customer creation failed:',
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
        .from('customers')
        .select(`
          id,
          customer_number,
          customer_type,
          first_name,
          last_name,
          phone,
          email,
          identification_type,
          identification_number,
          kyc_status,
          status,
          created_at,
          updated_at
        `)
        .eq('tenant_id', tenantId)
        .order('created_at', {
          ascending: false,
        });

    if (error) {
      console.error(
        'Customer lookup failed:',
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
    customerId: string,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('customers')
        .select(`
          id,
          customer_number,
          customer_type,
          first_name,
          last_name,
          phone,
          email,
          identification_type,
          identification_number,
          kyc_status,
          status,
          created_at,
          updated_at
        `)
        .eq('id', customerId)
        .eq('tenant_id', tenantId)
        .maybeSingle();

    if (error) {
      throw new BadRequestException(
        error.message,
      );
    }

    if (!data) {
      throw new NotFoundException(
        'Customer not found',
      );
    }

    return data;
  }

  async updateCustomer(
    tenantId: string,
    customerId: string,
    dto: UpdateCustomerDto,
  ) {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('customers')
        .update({
          first_name: dto.firstName,
          last_name: dto.lastName,
          phone: dto.phone,
          email: dto.email,
          identification_type:
            dto.identificationType,
          identification_number:
            dto.identificationNumber,
        })
        .eq('id', customerId)
        .eq('tenant_id', tenantId)
        .select()
        .maybeSingle();

    if (error) {
      throw new BadRequestException(
        error.message,
      );
    }

    if (!data) {
      throw new NotFoundException(
        'Customer not found',
      );
    }

    return data;
  }

  private async generateCustomerNumber(
    tenantId: string,
  ): Promise<string> {
    const supabase =
      this.supabaseService.getClient();

    const { data, error } =
      await supabase
        .from('customers')
        .select('customer_number')
        .eq('tenant_id', tenantId)
        .order('created_at', {
          ascending: false,
        })
        .limit(1)
        .maybeSingle();

    if (error) {
      throw new BadRequestException(
        'Unable to generate customer number',
      );
    }

    if (!data) {
      return 'CUS-000001';
    }

    const match =
      data.customer_number.match(
        /^CUS-(\d+)$/,
      );

    if (!match) {
      return `CUS-${Date.now()}`;
    }

    const nextNumber =
      Number(match[1]) + 1;

    return `CUS-${nextNumber
      .toString()
      .padStart(6, '0')}`;
  }
}

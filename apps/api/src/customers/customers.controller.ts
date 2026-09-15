import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';

import { AuthGuard } from '../auth/auth.guard';
import { PermissionsGuard } from '../auth/permissions.guard';
import { RequirePermissions } from '../auth/permissions.decorator';
import { CurrentUser } from '../auth/current-user.decorator';

import type { AuthenticatedUser } from '../auth/types/authenticated-user';

import { CustomersService } from './customers.service';
import { CreateCustomerDto } from './dto/create-customer.dto';
import { UpdateCustomerDto } from './dto/update-customer.dto';

@Controller('customers')
@UseGuards(
  AuthGuard,
  PermissionsGuard,
)
export class CustomersController {
  constructor(
    private readonly customersService: CustomersService,
  ) {}

  @Post()
  @RequirePermissions(
    'customers.create',
  )
  async createCustomer(
    @CurrentUser()
    user: AuthenticatedUser,

    @Body()
    dto: CreateCustomerDto,
  ) {
    return this.customersService.createCustomer(
      user.tenantId,
      dto,
    );
  }

  @Get()
  @RequirePermissions(
    'customers.read',
  )
  async findAll(
    @CurrentUser()
    user: AuthenticatedUser,
  ) {
    return this.customersService.findAll(
      user.tenantId,
    );
  }

  @Get(':id')
  @RequirePermissions(
    'customers.read',
  )
  async findOne(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    customerId: string,
  ) {
    return this.customersService.findOne(
      user.tenantId,
      customerId,
    );
  }

  @Patch(':id')
  @RequirePermissions(
    'customers.update',
  )
  async updateCustomer(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    customerId: string,

    @Body()
    dto: UpdateCustomerDto,
  ) {
    return this.customersService.updateCustomer(
      user.tenantId,
      customerId,
      dto,
    );
  }
}

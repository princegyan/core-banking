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

import { AccountsService } from './accounts.service';
import { CreateAccountDto } from './dto/create-account.dto';
import { UpdateAccountDto } from './dto/update-account.dto';

@Controller('accounts')
@UseGuards(
  AuthGuard,
  PermissionsGuard,
)
export class AccountsController {
  constructor(
    private readonly accountsService: AccountsService,
  ) {}

  @Post()
  @RequirePermissions(
    'accounts.create',
  )
  async createAccount(
    @CurrentUser()
    user: AuthenticatedUser,

    @Body()
    dto: CreateAccountDto,
  ) {
    return this.accountsService.createAccount(
      user.tenantId,
      dto,
    );
  }

  @Get()
  @RequirePermissions(
    'accounts.read',
  )
  async findAll(
    @CurrentUser()
    user: AuthenticatedUser,
  ) {
    return this.accountsService.findAll(
      user.tenantId,
    );
  }

  @Get(':id')
  @RequirePermissions(
    'accounts.read',
  )
  async findOne(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    accountId: string,
  ) {
    return this.accountsService.findOne(
      user.tenantId,
      accountId,
    );
  }

  @Patch(':id')
  @RequirePermissions(
    'accounts.update',
  )
  async updateAccountStatus(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    accountId: string,

    @Body()
    dto: UpdateAccountDto,
  ) {
    return this.accountsService.updateAccountStatus(
      user.tenantId,
      accountId,
      dto.status!,
    );
  }
}
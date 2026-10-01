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

import { LoanProductsService } from './loan-products.service';
import { CreateLoanProductDto } from './dto/create-loan-product.dto';
import { UpdateLoanProductDto } from './dto/update-loan-product.dto';
import { AddGlMappingDto } from './dto/add-gl-mapping.dto';
import { AddProductChargeDto } from './dto/add-product-charge.dto';

@Controller('loan-products')
@UseGuards(
  AuthGuard,
  PermissionsGuard,
)
export class LoanProductsController {
  constructor(
    private readonly loanProductsService: LoanProductsService,
  ) {}

  @Post()
  @RequirePermissions(
    'loan-products.create',
  )
  async create(
    @CurrentUser()
    user: AuthenticatedUser,

    @Body()
    dto: CreateLoanProductDto,
  ) {
    return this.loanProductsService.create(
      user.tenantId,
      user.id,
      dto,
    );
  }

  @Get()
  @RequirePermissions(
    'loan-products.read',
  )
  async findAll(
    @CurrentUser()
    user: AuthenticatedUser,
  ) {
    return this.loanProductsService.findAll(
      user.tenantId,
    );
  }

  @Get(':id')
  @RequirePermissions(
    'loan-products.read',
  )
  async findOne(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    productId: string,
  ) {
    return this.loanProductsService.findOne(
      user.tenantId,
      productId,
    );
  }

  @Patch(':id')
  @RequirePermissions(
    'loan-products.update',
  )
  async update(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    productId: string,

    @Body()
    dto: UpdateLoanProductDto,
  ) {
    return this.loanProductsService.update(
      user.tenantId,
      productId,
      dto,
    );
  }

  @Post(':id/gl-mappings')
  @RequirePermissions(
    'loan-products.update',
  )
  async addGlMapping(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    productId: string,

    @Body()
    dto: AddGlMappingDto,
  ) {
    return this.loanProductsService.addGlMapping(
      user.tenantId,
      productId,
      dto,
    );
  }

  @Get(':id/gl-mappings')
  @RequirePermissions(
    'loan-products.read',
  )
  async getGlMappings(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    productId: string,
  ) {
    return this.loanProductsService.getGlMappings(
      user.tenantId,
      productId,
    );
  }

  @Post(':id/charges')
  @RequirePermissions(
    'loan-products.update',
  )
  async addCharge(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    productId: string,

    @Body()
    dto: AddProductChargeDto,
  ) {
    return this.loanProductsService.addCharge(
      user.tenantId,
      productId,
      dto,
    );
  }

  @Get(':id/charges')
  @RequirePermissions(
    'loan-products.read',
  )
  async getCharges(
    @CurrentUser()
    user: AuthenticatedUser,

    @Param('id')
    productId: string,
  ) {
    return this.loanProductsService.getCharges(
      user.tenantId,
      productId,
    );
  }
}
